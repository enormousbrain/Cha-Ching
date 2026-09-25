-- Self-chosen plans are context for recognition, never automatic star awards.
create table public.child_chore_plans (
  occurrence_id uuid primary key references public.task_occurrences(id) on delete cascade,
  child_id uuid not null references public.child_profiles(id) on delete cascade,
  planned_for timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  cancelled_at timestamptz
);
create index child_chore_plans_child on public.child_chore_plans(child_id);
alter table public.child_chore_plans enable row level security;
create policy "child and parents can read plans" on public.child_chore_plans for select to authenticated
  using (public.is_linked_child_profile(child_id) or exists(select 1 from public.child_profiles c where c.id=child_id and public.is_family_parent(c.family_id)));
revoke all on public.child_chore_plans from anon,authenticated;
grant select on public.child_chore_plans to authenticated;

create function public.set_child_chore_plan(target_occurrence_id uuid, target_planned_for timestamptz default null)
returns void language plpgsql security definer set search_path=public as $$
declare task public.task_occurrences%rowtype;
begin
  perform 1 from public.weeks where id=(select week_id from public.task_occurrences where id=target_occurrence_id) for update;
  select * into task from public.task_occurrences where id=target_occurrence_id for update;
  if task.id is null or not public.is_linked_child_profile(task.child_id) or not exists(
    select 1 from public.weeks w join public.family_members m on m.family_id=w.family_id
      where w.id=task.week_id and m.user_id=auth.uid() and m.role='child'
  ) then raise exception 'Only the assigned child can choose this plan.'; end if;
  if task.status not in ('upcoming','due') or exists(select 1 from public.allowance_settlements where week_id=task.week_id) then
    raise exception 'This chore is no longer available to plan.';
  end if;
  if target_planned_for is null then
    update public.child_chore_plans set cancelled_at=now(),updated_at=now() where occurrence_id=task.id and cancelled_at is null;
    return;
  end if;
  if task.due_at<=now() or target_planned_for<now()-interval '1 minute' or target_planned_for>task.due_at
    or not exists(select 1 from public.chore_definitions where id=task.chore_definition_id and not is_paused and archived_at is null) then
    raise exception 'Choose a time between now and the chore due time.';
  end if;
  insert into public.child_chore_plans(occurrence_id,child_id,planned_for)
    values(task.id,task.child_id,target_planned_for)
    on conflict(occurrence_id) do update set planned_for=excluded.planned_for,updated_at=now(),cancelled_at=null
      where child_chore_plans.planned_for is distinct from excluded.planned_for or child_chore_plans.cancelled_at is not null;
end $$;
revoke all on function public.set_child_chore_plan(uuid,timestamptz) from public,anon;
grant execute on function public.set_child_chore_plan(uuid,timestamptz) to authenticated;
notify pgrst,'reload schema';
