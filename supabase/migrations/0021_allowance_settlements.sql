-- Remember the reduction already applied during rollover so late decisions can reconcile it.
alter table public.weeks add column rollover_reduction_cents integer check (rollover_reduction_cents >= 0);
update public.weeks w set rollover_reduction_cents = least(f.weekly_base_allowance_cents,
  greatest(0, -coalesce((select sum(case when l.entry_type = 'deduction' then -l.amount_cents else l.amount_cents end)
    from public.ledger_entries l where l.week_id = w.id and not l.is_voided), 0)))
from public.families f where f.id = w.family_id and w.archived_at is not null;

create function public.capture_allowance_rollover() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if OLD.archived_at is null and NEW.archived_at is not null then
    select least(f.weekly_base_allowance_cents, greatest(0, -coalesce((
      select sum(case when l.entry_type = 'deduction' then -l.amount_cents else l.amount_cents end)
      from public.ledger_entries l where l.week_id = NEW.id and not l.is_voided), 0)))
    into NEW.rollover_reduction_cents from public.families f where f.id = NEW.family_id;
  end if;
  return NEW;
end;
$$;
create trigger capture_allowance_rollover before update on public.weeks
for each row execute function public.capture_allowance_rollover();

create table public.allowance_settlements (
  week_id uuid primary key references public.weeks(id) on delete cascade,
  amount_cents integer not null check (amount_cents >= 0),
  confirmed_at timestamptz not null default now(),
  confirmed_by uuid not null references auth.users(id),
  paid_at timestamptz,
  paid_by uuid references auth.users(id),
  check ((paid_at is null) = (paid_by is null))
);
alter table public.allowance_settlements enable row level security;
create policy settlements_read on public.allowance_settlements for select to authenticated
using (exists (
  select 1 from public.weeks w where w.id = week_id
  and (public.is_family_parent(w.family_id) or exists (
    select 1 from public.child_profiles c where c.id = w.child_id and c.linked_user_id = auth.uid()
  ))
));
revoke all on public.allowance_settlements from anon, authenticated;
grant select on public.allowance_settlements to authenticated;

-- Financial and review changes take the same period lock as closeout.
create function public.guard_settled_period_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare target_week uuid;
begin
  target_week := case when TG_OP = 'DELETE' then OLD.week_id else NEW.week_id end;
  perform 1 from public.weeks where id = target_week for update;
  if exists (select 1 from public.allowance_settlements where week_id = target_week) then
    raise exception 'This allowance period is confirmed and cannot be changed.' using errcode = '22023';
  end if;
  if TG_OP = 'UPDATE' and OLD.week_id is distinct from NEW.week_id then
    raise exception 'Moving entries between allowance periods is not supported.' using errcode = '22023';
  end if;
  if TG_OP = 'DELETE' then return OLD; end if;
  return NEW;
end;
$$;
create trigger lock_settled_ledger before insert or update or delete on public.ledger_entries
for each row execute function public.guard_settled_period_changes();
create trigger lock_settled_occurrences before insert or update or delete on public.task_occurrences
for each row execute function public.guard_settled_period_changes();

create function public.confirm_allowance_period(target_week_id uuid, expected_amount_cents integer)
returns setof public.allowance_settlements
language plpgsql security definer set search_path = public as $$
declare w public.weeks; following public.weeks; result public.allowance_settlements;
  total integer; raw_total integer; carryover_change integer;
begin
  select * into w from public.weeks where id = target_week_id for update;
  if w.id is null or not public.is_family_parent(w.family_id) then
    raise exception 'Only a family parent can confirm allowance.' using errcode = '42501';
  end if;
  select * into result from public.allowance_settlements where week_id = w.id;
  if found then return next result; return; end if;
  if w.archived_at is null or w.ends_at > now() then
    raise exception 'Wait until this allowance period ends.' using errcode = '22023';
  end if;
  if exists (select 1 from public.weeks earlier where earlier.child_id = w.child_id
    and earlier.family_id = w.family_id and earlier.starts_at < w.starts_at and earlier.archived_at is not null
    and not exists (select 1 from public.allowance_settlements s where s.week_id = earlier.id)) then
    raise exception 'Confirm older allowance periods first.' using errcode = '22023';
  end if;
  if exists (select 1 from public.task_occurrences where week_id = w.id
    and status in ('upcoming', 'due', 'submitted', 'ai_reviewed')) then
    raise exception 'Resolve all pending chores and reviews before confirming allowance.' using errcode = '22023';
  end if;
  select coalesce(sum(case when entry_type = 'deduction' then -amount_cents else amount_cents end), 0)
  into raw_total from public.ledger_entries where week_id = w.id and not is_voided;
  total := greatest(0, raw_total);
  if total is distinct from expected_amount_cents then
    raise exception 'The allowance amount changed. Refresh and review it again.' using errcode = '22023';
  end if;
  select * into following from public.weeks where family_id = w.family_id and child_id = w.child_id
    and starts_at > w.starts_at order by starts_at limit 1 for update;
  if following.id is not null then
    carryover_change := coalesce(w.rollover_reduction_cents, 0) - least(
      following.base_allowance_cents + coalesce(w.rollover_reduction_cents, 0), greatest(0, -raw_total));
    if carryover_change <> 0 then
      insert into public.ledger_entries(week_id, child_id, created_by, entry_type, title, amount_cents, note)
      values (following.id, w.child_id, auth.uid(), case when carryover_change > 0 then 'adjustment' else 'deduction' end,
        'Prior period carryover correction', abs(carryover_change), 'Reconciled when the prior allowance period was confirmed.');
    end if;
  elsif raw_total < 0 then
    raise exception 'Refresh the allowance schedule before confirming this period.' using errcode = '22023';
  end if;
  insert into public.allowance_settlements(week_id, amount_cents, confirmed_by)
  values(w.id, total, auth.uid()) returning * into result;
  return next result;
end;
$$;

create function public.mark_allowance_paid(target_week_id uuid)
returns setof public.allowance_settlements
language plpgsql security definer set search_path = public as $$
declare w public.weeks; result public.allowance_settlements;
begin
  select * into w from public.weeks where id = target_week_id for update;
  if w.id is null or not public.is_family_parent(w.family_id) then
    raise exception 'Only a family parent can record payment.' using errcode = '42501';
  end if;
  update public.allowance_settlements set paid_at = coalesce(paid_at, now()), paid_by = coalesce(paid_by, auth.uid())
  where week_id = w.id returning * into result;
  if not found then raise exception 'Confirm this allowance period first.' using errcode = '22023'; end if;
  return next result;
end;
$$;
revoke all on function public.confirm_allowance_period(uuid, integer) from public, anon;
revoke all on function public.mark_allowance_paid(uuid) from public, anon;
grant execute on function public.confirm_allowance_period(uuid, integer) to authenticated;
grant execute on function public.mark_allowance_paid(uuid) to authenticated;

notify pgrst, 'reload schema';
