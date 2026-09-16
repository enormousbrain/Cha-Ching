create or replace function public.process_task_occurrence_deadlines_internal(
  target_family_id uuid,
  target_child_profile_id uuid,
  maintenance_at timestamptz default now()
)
returns table (
  marked_due_count integer,
  marked_missed_count integer,
  deduction_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  due_rows integer := 0;
  missed_rows integer := 0;
  deduction_rows integer := 0;
begin
  if not exists (
    select 1
    from public.child_profiles
    where id = target_child_profile_id
      and family_id = target_family_id
  ) then
    raise exception 'child_profile_not_in_family' using errcode = '22023';
  end if;

  update public.task_occurrences occurrence
  set
    status = 'due',
    updated_at = maintenance_at
  from public.chore_definitions chore
  where occurrence.chore_definition_id = chore.id
    and chore.family_id = target_family_id
    and occurrence.child_id = target_child_profile_id
    and occurrence.status = 'upcoming'
    and occurrence.due_at <= maintenance_at
    and occurrence.expires_at > maintenance_at;

  get diagnostics due_rows = row_count;

  with missed_occurrences as (
    update public.task_occurrences occurrence
    set
      status = 'missed',
      updated_at = maintenance_at
    from public.chore_definitions chore
    where occurrence.chore_definition_id = chore.id
      and chore.family_id = target_family_id
      and occurrence.child_id = target_child_profile_id
      and occurrence.status in ('upcoming', 'due')
      and occurrence.expires_at <= maintenance_at
    returning
      occurrence.id,
      occurrence.week_id,
      occurrence.child_id,
      chore.title,
      chore.deduction_cents
  ), inserted_deductions as (
    insert into public.ledger_entries (
      week_id,
      child_id,
      entry_type,
      title,
      amount_cents,
      related_occurrence_id,
      note,
      created_at
    )
    select
      missed_occurrences.week_id,
      missed_occurrences.child_id,
      'deduction',
      'Missed: ' || missed_occurrences.title,
      missed_occurrences.deduction_cents,
      missed_occurrences.id,
      'Automatically applied after the chore window closed.',
      maintenance_at
    from missed_occurrences
    on conflict do nothing
    returning id
  )
  select
    (select count(*) from missed_occurrences)::integer,
    (select count(*) from inserted_deductions)::integer
  into missed_rows, deduction_rows;

  update public.task_occurrences occurrence
  set deduction_ledger_entry_id = ledger.id
  from public.ledger_entries ledger, public.chore_definitions chore
  where occurrence.child_id = target_child_profile_id
    and chore.id = occurrence.chore_definition_id
    and chore.family_id = target_family_id
    and occurrence.status = 'missed'
    and ledger.related_occurrence_id = occurrence.id
    and ledger.entry_type = 'deduction'
    and ledger.is_voided = false
    and occurrence.deduction_ledger_entry_id is distinct from ledger.id;

  return query select due_rows, missed_rows, deduction_rows;
end;
$$;

revoke all on function public.process_task_occurrence_deadlines_internal(uuid, uuid, timestamptz)
  from public, anon, authenticated;

create or replace function public.process_task_occurrence_deadlines(
  target_family_id uuid,
  target_child_profile_id uuid
)
returns table (
  marked_due_count integer,
  marked_missed_count integer,
  deduction_count integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not public.is_family_member(target_family_id) then
    raise exception 'not_a_family_member' using errcode = '42501';
  end if;

  return query
  select *
  from public.process_task_occurrence_deadlines_internal(
    target_family_id,
    target_child_profile_id,
    now()
  );
end;
$$;

revoke all on function public.process_task_occurrence_deadlines(uuid, uuid) from public, anon;
grant execute on function public.process_task_occurrence_deadlines(uuid, uuid) to authenticated;

create or replace function public.maintain_allowance_schedule_internal(
  target_family_id uuid,
  target_child_profile_id uuid,
  maintenance_at timestamptz default now()
)
returns table (
  active_week_id uuid,
  inserted_count integer,
  closed_period_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  family_record public.families%rowtype;
  current_week_record public.weeks%rowtype;
  family_timezone text;
  period_days integer;
  local_today date;
  reference_local_date date;
  boundary_local_date date;
  target_weekday integer;
  days_until_boundary integer;
  next_boundary timestamptz;
  next_period_boundary timestamptz;
  period_start_at timestamptz;
  previous_raw_total integer := 0;
  period_base_allowance integer;
  current_week_id uuid;
  recurrence_type text;
  due_time_value time;
  due_at_value timestamptz;
  should_create boolean;
  weekday_value integer;
  rows_added integer := 0;
  affected_rows integer;
  periods_closed integer := 0;
  chore_record public.chore_definitions%rowtype;
begin
  select families.*
  into family_record
  from public.families
  where families.id = target_family_id
  for update;

  if family_record.id is null then
    raise exception 'family_not_found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1
    from public.child_profiles
    where id = target_child_profile_id
      and family_id = target_family_id
  ) then
    raise exception 'child_profile_not_in_family' using errcode = '22023';
  end if;

  family_timezone := coalesce(nullif(family_record.timezone, ''), 'UTC');
  period_days := case
    when family_record.allowance_cadence = 'every_two_weeks' then 14
    else 7
  end;
  local_today := (maintenance_at at time zone family_timezone)::date;
  next_boundary := family_record.next_allowance_at;

  select weeks.*
  into current_week_record
  from public.weeks
  where weeks.family_id = target_family_id
    and weeks.child_id = target_child_profile_id
    and weeks.archived_at is null
  order by weeks.starts_at desc
  limit 1
  for update;

  if family_record.allowance_cadence = 'weekly' then
    reference_local_date := case
      when current_week_record.id is null then local_today
      else (current_week_record.starts_at at time zone family_timezone)::date
    end;
    target_weekday := family_record.allowance_weekday - 1;
    days_until_boundary := (
      target_weekday - extract(dow from reference_local_date)::integer + 7
    ) % 7;
    boundary_local_date := reference_local_date + days_until_boundary;
    next_boundary := boundary_local_date::timestamp at time zone family_timezone;

    if current_week_record.id is not null
       and next_boundary <= current_week_record.starts_at then
      boundary_local_date := boundary_local_date + 7;
      next_boundary := boundary_local_date::timestamp at time zone family_timezone;
    elsif current_week_record.id is null and next_boundary <= maintenance_at then
      boundary_local_date := boundary_local_date + 7;
      next_boundary := boundary_local_date::timestamp at time zone family_timezone;
    end if;
  else
    boundary_local_date := (family_record.next_allowance_at at time zone family_timezone)::date;
    next_boundary := boundary_local_date::timestamp at time zone family_timezone;

    while next_boundary <= coalesce(current_week_record.starts_at, maintenance_at) loop
      boundary_local_date := boundary_local_date + 14;
      next_boundary := boundary_local_date::timestamp at time zone family_timezone;
    end loop;
  end if;

  if current_week_record.id is null then
    if next_boundary > maintenance_at then
      period_start_at := local_today::timestamp at time zone family_timezone;
    else
      period_start_at := (
        (next_boundary at time zone family_timezone) - make_interval(days => period_days)
      ) at time zone family_timezone;
    end if;

    insert into public.weeks (
      family_id,
      child_id,
      starts_at,
      ends_at,
      base_allowance_cents
    )
    values (
      target_family_id,
      target_child_profile_id,
      period_start_at,
      next_boundary,
      family_record.weekly_base_allowance_cents
    )
    on conflict (family_id, child_id, starts_at)
    do update set ends_at = excluded.ends_at
    returning id, base_allowance_cents
    into current_week_id, period_base_allowance;

    insert into public.ledger_entries (
      week_id,
      child_id,
      entry_type,
      title,
      amount_cents,
      created_at
    )
    select
      current_week_id,
      target_child_profile_id,
      'weekly_base',
      'Starting allowance',
      period_base_allowance,
      period_start_at
    where not exists (
      select 1
      from public.ledger_entries
      where week_id = current_week_id
        and child_id = target_child_profile_id
        and entry_type = 'weekly_base'
        and is_voided = false
    )
    on conflict do nothing;
  else
    current_week_id := current_week_record.id;

    if current_week_record.starts_at < next_boundary
       and current_week_record.ends_at is distinct from next_boundary then
      update public.weeks
      set ends_at = next_boundary
      where id = current_week_id;
    end if;
  end if;

  while next_boundary <= maintenance_at loop
    with closing_occurrences as (
      update public.task_occurrences occurrence
      set
        status = 'missed',
        updated_at = next_boundary
      from public.chore_definitions chore
      where occurrence.week_id = current_week_id
        and occurrence.chore_definition_id = chore.id
        and occurrence.status in ('upcoming', 'due')
      returning
        occurrence.id,
        occurrence.week_id,
        occurrence.child_id,
        chore.title,
        chore.deduction_cents
    )
    insert into public.ledger_entries (
      week_id,
      child_id,
      entry_type,
      title,
      amount_cents,
      related_occurrence_id,
      note,
      created_at
    )
    select
      closing_occurrences.week_id,
      closing_occurrences.child_id,
      'deduction',
      'Missed: ' || closing_occurrences.title,
      closing_occurrences.deduction_cents,
      closing_occurrences.id,
      'Automatically applied when the allowance period closed.',
      next_boundary
    from closing_occurrences
    on conflict do nothing;

    update public.task_occurrences occurrence
    set deduction_ledger_entry_id = ledger.id
    from public.ledger_entries ledger
    where occurrence.week_id = current_week_id
      and occurrence.status = 'missed'
      and ledger.related_occurrence_id = occurrence.id
      and ledger.entry_type = 'deduction'
      and ledger.is_voided = false
      and occurrence.deduction_ledger_entry_id is distinct from ledger.id;

    select coalesce(sum(
      case ledger_entries.entry_type
        when 'deduction' then -ledger_entries.amount_cents
        else ledger_entries.amount_cents
      end
    ), 0)::integer
    into previous_raw_total
    from public.ledger_entries
    where ledger_entries.week_id = current_week_id
      and ledger_entries.child_id = target_child_profile_id
      and ledger_entries.is_voided = false;

    update public.weeks
    set
      ends_at = next_boundary,
      archived_at = coalesce(archived_at, next_boundary),
      final_balance_cents = greatest(0, previous_raw_total)
    where id = current_week_id;

    periods_closed := periods_closed + 1;
    period_base_allowance := greatest(
      0,
      family_record.weekly_base_allowance_cents - greatest(0, -previous_raw_total)
    );
    period_start_at := next_boundary;
    next_period_boundary := (
      (next_boundary at time zone family_timezone) + make_interval(days => period_days)
    ) at time zone family_timezone;

    insert into public.weeks (
      family_id,
      child_id,
      starts_at,
      ends_at,
      base_allowance_cents
    )
    values (
      target_family_id,
      target_child_profile_id,
      period_start_at,
      next_period_boundary,
      period_base_allowance
    )
    on conflict (family_id, child_id, starts_at)
    do update set ends_at = excluded.ends_at
    returning id, base_allowance_cents
    into current_week_id, period_base_allowance;

    insert into public.ledger_entries (
      week_id,
      child_id,
      entry_type,
      title,
      amount_cents,
      created_at
    )
    select
      current_week_id,
      target_child_profile_id,
      'weekly_base',
      'Starting allowance',
      period_base_allowance,
      period_start_at
    where not exists (
      select 1
      from public.ledger_entries
      where week_id = current_week_id
        and child_id = target_child_profile_id
        and entry_type = 'weekly_base'
        and is_voided = false
    )
    on conflict do nothing;

    next_boundary := next_period_boundary;
  end loop;

  update public.families
  set next_allowance_at = next_boundary
  where id = target_family_id
    and next_allowance_at is distinct from next_boundary;

  weekday_value := extract(dow from local_today)::integer + 1;

  for chore_record in
    select chore_definitions.*
    from public.chore_definitions
    where chore_definitions.family_id = target_family_id
      and chore_definitions.child_id = target_child_profile_id
      and chore_definitions.is_paused = false
      and chore_definitions.archived_at is null
  loop
    recurrence_type := coalesce(chore_record.recurrence ->> 'type', 'daily');
    should_create := case recurrence_type
      when 'daily' then true
      when 'weekly' then coalesce(
        (chore_record.recurrence -> 'weekdays') @> jsonb_build_array(weekday_value),
        false
      )
      when 'once' then coalesce(
        ((chore_record.recurrence ->> 'due_at')::timestamptz at time zone family_timezone)::date = local_today,
        false
      )
      else false
    end;

    if not should_create then
      continue;
    end if;

    begin
      due_time_value := (chore_record.recurrence -> 'times' ->> 0)::time;
    exception when others then
      continue;
    end;

    due_at_value := (local_today + due_time_value) at time zone family_timezone;

    insert into public.task_occurrences (
      chore_definition_id,
      child_id,
      week_id,
      scheduled_at,
      due_at,
      expires_at,
      status
    )
    select
      chore_record.id,
      target_child_profile_id,
      current_week_id,
      due_at_value,
      due_at_value,
      due_at_value + make_interval(mins => chore_record.due_window_minutes),
      case when due_at_value <= maintenance_at then 'due' else 'upcoming' end
    where not exists (
      select 1
      from public.task_occurrences existing_occurrence
      where existing_occurrence.chore_definition_id = chore_record.id
        and existing_occurrence.child_id = target_child_profile_id
        and (existing_occurrence.scheduled_at at time zone family_timezone)::date = local_today
    )
    on conflict (chore_definition_id, child_id, scheduled_at) do nothing;

    get diagnostics affected_rows = row_count;
    rows_added := rows_added + affected_rows;
  end loop;

  active_week_id := current_week_id;
  inserted_count := rows_added;
  closed_period_count := periods_closed;
  return next;
end;
$$;

revoke all on function public.maintain_allowance_schedule_internal(uuid, uuid, timestamptz)
  from public, anon, authenticated;

create or replace function public.ensure_current_task_occurrences(
  target_family_id uuid,
  target_child_profile_id uuid
)
returns table (
  active_week_id uuid,
  inserted_count integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not public.is_family_member(target_family_id) then
    raise exception 'not_a_family_member' using errcode = '42501';
  end if;

  return query
  select maintenance.active_week_id, maintenance.inserted_count
  from public.maintain_allowance_schedule_internal(
    target_family_id,
    target_child_profile_id,
    now()
  ) maintenance;
end;
$$;

revoke all on function public.ensure_current_task_occurrences(uuid, uuid) from public, anon;
grant execute on function public.ensure_current_task_occurrences(uuid, uuid) to authenticated;

create or replace function public.run_family_maintenance(
  maintenance_at timestamptz default now()
)
returns table (
  processed_child_count integer,
  inserted_occurrence_count integer,
  closed_period_count integer,
  marked_missed_count integer,
  deduction_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_record record;
  maintenance_result record;
  deadline_result record;
  processed_children integer := 0;
  inserted_occurrences integer := 0;
  closed_periods integer := 0;
  marked_missed integer := 0;
  created_deductions integer := 0;
begin
  for profile_record in
    select child_profiles.id, child_profiles.family_id
    from public.child_profiles
    order by child_profiles.family_id, child_profiles.created_at
  loop
    select *
    into deadline_result
    from public.process_task_occurrence_deadlines_internal(
      profile_record.family_id,
      profile_record.id,
      maintenance_at
    );

    select *
    into maintenance_result
    from public.maintain_allowance_schedule_internal(
      profile_record.family_id,
      profile_record.id,
      maintenance_at
    );

    processed_children := processed_children + 1;
    inserted_occurrences := inserted_occurrences + coalesce(maintenance_result.inserted_count, 0);
    closed_periods := closed_periods + coalesce(maintenance_result.closed_period_count, 0);
    marked_missed := marked_missed + coalesce(deadline_result.marked_missed_count, 0);
    created_deductions := created_deductions + coalesce(deadline_result.deduction_count, 0);
  end loop;

  return query
  select
    processed_children,
    inserted_occurrences,
    closed_periods,
    marked_missed,
    created_deductions;
end;
$$;

revoke all on function public.run_family_maintenance(timestamptz)
  from public, anon, authenticated;
grant execute on function public.run_family_maintenance(timestamptz) to service_role;

create extension if not exists pg_cron;

do $$
declare
  existing_job_id bigint;
begin
  for existing_job_id in
    select jobid
    from cron.job
    where jobname = 'chaching-family-maintenance'
  loop
    perform cron.unschedule(existing_job_id);
  end loop;
end;
$$;

select cron.schedule(
  'chaching-family-maintenance',
  '*/15 * * * *',
  'select public.run_family_maintenance();'
);
