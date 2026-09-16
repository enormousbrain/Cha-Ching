\set ON_ERROR_STOP on

begin;

do $$
declare
  test_family_id uuid := gen_random_uuid();
  test_child_id uuid := gen_random_uuid();
  previous_week_id uuid := gen_random_uuid();
  test_chore_id uuid := gen_random_uuid();
  boundary timestamptz := date_trunc('day', now());
  result_record record;
  current_week_record public.weeks%rowtype;
  current_base_entry integer;
  previous_final_balance integer;
  previous_archived_at timestamptz;
  next_boundary timestamptz;
  occurrence_count integer;
begin
  insert into public.families (
    id,
    name,
    weekly_base_allowance_cents,
    timezone,
    allowance_cadence,
    allowance_weekday,
    next_allowance_at
  )
  values (
    test_family_id,
    'Automatic maintenance rollback test',
    1500,
    'UTC',
    'weekly',
    extract(dow from boundary)::integer + 1,
    boundary
  );

  insert into public.child_profiles (id, family_id, display_name)
  values (test_child_id, test_family_id, 'Test Child');

  insert into public.weeks (
    id,
    family_id,
    child_id,
    starts_at,
    ends_at,
    base_allowance_cents
  )
  values (
    previous_week_id,
    test_family_id,
    test_child_id,
    boundary - interval '7 days',
    boundary,
    1500
  );

  insert into public.ledger_entries (
    week_id,
    child_id,
    entry_type,
    title,
    amount_cents
  )
  values
    (previous_week_id, test_child_id, 'weekly_base', 'Starting allowance', 1500),
    (previous_week_id, test_child_id, 'deduction', 'Large deduction', 2000);

  insert into public.chore_definitions (
    id,
    family_id,
    child_id,
    title,
    short_title,
    deduction_cents,
    verification_mode,
    recurrence,
    due_window_minutes,
    reminder_offsets_minutes
  )
  values (
    test_chore_id,
    test_family_id,
    test_child_id,
    'Daily rollback chore',
    'Daily chore',
    50,
    'no_verification',
    jsonb_build_object('type', 'daily', 'times', jsonb_build_array('11:59 PM')),
    90,
    array[15, 0]
  );

  select *
  into result_record
  from public.maintain_allowance_schedule_internal(
    test_family_id,
    test_child_id,
    now()
  );

  if result_record.closed_period_count <> 1 then
    raise exception 'expected_one_closed_period';
  end if;

  select final_balance_cents, archived_at
  into previous_final_balance, previous_archived_at
  from public.weeks
  where id = previous_week_id;

  if previous_final_balance <> 0 or previous_archived_at is null then
    raise exception 'previous_period_not_archived';
  end if;

  select *
  into current_week_record
  from public.weeks
  where id = result_record.active_week_id;

  if current_week_record.starts_at <> boundary
     or current_week_record.base_allowance_cents <> 1000 then
    raise exception 'rollover_base_allowance_failed starts_at=% expected=% base=%',
      current_week_record.starts_at,
      boundary,
      current_week_record.base_allowance_cents;
  end if;

  select amount_cents
  into current_base_entry
  from public.ledger_entries
  where week_id = current_week_record.id
    and entry_type = 'weekly_base'
    and is_voided = false;

  if current_base_entry <> 1000 then
    raise exception 'weekly_base_entry_failed';
  end if;

  select next_allowance_at
  into next_boundary
  from public.families
  where id = test_family_id;

  if next_boundary <> boundary + interval '7 days' then
    raise exception 'next_allowance_boundary_failed';
  end if;

  select count(*)
  into occurrence_count
  from public.task_occurrences
  where chore_definition_id = test_chore_id
    and week_id = current_week_record.id;

  if occurrence_count <> 1 then
    raise exception 'daily_occurrence_generation_failed';
  end if;
end;
$$;

do $$
declare
  test_family_id uuid := gen_random_uuid();
  test_child_id uuid := gen_random_uuid();
  test_week_id uuid := gen_random_uuid();
  first_boundary timestamptz := '2026-11-01 00:00:00 Pacific/Kiritimati';
  maintenance_at timestamptz := '2026-11-01 00:15:00 Pacific/Kiritimati';
  result_record record;
  current_week_record public.weeks%rowtype;
  next_boundary timestamptz;
begin
  insert into public.families (
    id,
    name,
    weekly_base_allowance_cents,
    timezone,
    allowance_cadence,
    allowance_weekday,
    next_allowance_at
  )
  values (
    test_family_id,
    'Biweekly timezone rollback test',
    1500,
    'Pacific/Kiritimati',
    'every_two_weeks',
    1,
    first_boundary
  );

  insert into public.child_profiles (id, family_id, display_name)
  values (test_child_id, test_family_id, 'Test Child');

  insert into public.weeks (
    id,
    family_id,
    child_id,
    starts_at,
    ends_at,
    base_allowance_cents
  )
  values (
    test_week_id,
    test_family_id,
    test_child_id,
    first_boundary - interval '14 days',
    first_boundary,
    1500
  );

  insert into public.ledger_entries (
    week_id,
    child_id,
    entry_type,
    title,
    amount_cents
  )
  values (test_week_id, test_child_id, 'weekly_base', 'Starting allowance', 1500);

  select *
  into result_record
  from public.maintain_allowance_schedule_internal(
    test_family_id,
    test_child_id,
    maintenance_at
  );

  if result_record.closed_period_count <> 1 then
    raise exception 'expected_one_biweekly_closed_period';
  end if;

  select *
  into current_week_record
  from public.weeks
  where id = result_record.active_week_id;

  if current_week_record.starts_at <> first_boundary
     or current_week_record.ends_at <> '2026-11-15 00:00:00 Pacific/Kiritimati'::timestamptz then
    raise exception 'biweekly_timezone_boundary_failed starts_at=% ends_at=%',
      current_week_record.starts_at,
      current_week_record.ends_at;
  end if;

  select next_allowance_at
  into next_boundary
  from public.families
  where id = test_family_id;

  if next_boundary <> '2026-11-15 00:00:00 Pacific/Kiritimati'::timestamptz then
    raise exception 'biweekly_next_allowance_boundary_failed';
  end if;
end;
$$;

select 'automatic_family_maintenance_smoke_test=ok' as result;

rollback;
