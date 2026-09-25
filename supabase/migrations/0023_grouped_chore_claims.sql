-- NULL means ordinary evidence; an empty string means a no-photo claim without a note.
alter table public.chore_submissions add column if not exists reported_done_note text
  check (length(reported_done_note) <= 1000);

create or replace function public.report_chores_done(target_occurrence_ids uuid[], target_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  task public.task_occurrences%rowtype;
  submission public.chore_submissions%rowtype;
  note text := coalesce(trim(target_note), '');
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if coalesce(cardinality(target_occurrence_ids),0) not between 1 and 100 or length(note)>1000 then
    raise exception 'Choose between 1 and 100 chores and a note under 1000 characters.';
  end if;
  if (select count(distinct id) from public.task_occurrences where id=any(target_occurrence_ids)) <> cardinality(target_occurrence_ids) then
    raise exception 'Chore selection changed. Refresh and try again.';
  end if;
  if (select count(distinct (child_id,chore_definition_id)) from public.task_occurrences where id=any(target_occurrence_ids)) <> 1 then
    raise exception 'Select one chore group at a time.';
  end if;
  perform 1 from public.weeks where id in (select week_id from public.task_occurrences where id=any(target_occurrence_ids)) order by id for update;
  for task in select * from public.task_occurrences where id=any(target_occurrence_ids) order by id for update loop
    if not public.is_linked_child_profile(task.child_id) or not exists (
      select 1 from public.family_members m join public.weeks w on w.family_id=m.family_id
      where w.id=task.week_id and m.user_id=auth.uid() and m.role='child'
    ) then raise exception 'Only the assigned child can report these chores.'; end if;
    if exists(select 1 from public.allowance_settlements where week_id=task.week_id) then
      raise exception 'This allowance period is already confirmed.';
    end if;
    if task.status='submitted' then
      select * into submission from public.chore_submissions where id=task.submission_id;
      if submission.reported_done_note is not null and submission.reported_done_note=note then continue; end if;
    end if;
    if task.status not in ('upcoming','due','missed') then
      raise exception 'A selected chore has already been submitted or reviewed. Refresh and try again.';
    end if;
    insert into public.chore_submissions(task_occurrence_id,child_id,image_path,reported_done_note)
      values(task.id,task.child_id,null,note) returning * into submission;
    update public.task_occurrences set submission_id=submission.id,status='submitted',excuse_reason=null,updated_at=now()
      where id=task.id;
  end loop;
end;
$$;
revoke all on function public.report_chores_done(uuid[],text) from public,anon;
grant execute on function public.report_chores_done(uuid[],text) to authenticated;

create or replace function public.review_chore_batch(target_occurrence_ids uuid[], target_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare task public.task_occurrences%rowtype;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if coalesce(cardinality(target_occurrence_ids),0) not between 1 and 100 or
    target_decision is null or target_decision not in ('approved','rejected','excused') then
    raise exception 'Invalid review selection.';
  end if;
  if (select count(distinct id) from public.task_occurrences where id=any(target_occurrence_ids)) <> cardinality(target_occurrence_ids) then
    raise exception 'Chore selection changed. Refresh and try again.';
  end if;
  if (select count(distinct (child_id,chore_definition_id)) from public.task_occurrences where id=any(target_occurrence_ids)) <> 1 then
    raise exception 'Select one child and chore group at a time.';
  end if;
  perform 1 from public.weeks where id in (select week_id from public.task_occurrences where id=any(target_occurrence_ids)) order by id for update;
  for task in select * from public.task_occurrences where id=any(target_occurrence_ids) order by id for update loop
    if not exists(select 1 from public.weeks where id=task.week_id and public.is_family_parent(family_id)) then
      raise exception 'Only a family parent can review these chores.';
    end if;
    if exists(select 1 from public.allowance_settlements where week_id=task.week_id) then
      raise exception 'This allowance period is already confirmed.';
    end if;
    if task.status not in ('submitted','ai_reviewed') then
      raise exception 'A selected chore has already been reviewed. Refresh and try again.';
    end if;
    perform public.decide_chore_submission(task.id,target_decision);
  end loop;
end;
$$;
revoke all on function public.review_chore_batch(uuid[],text) from public,anon;
grant execute on function public.review_chore_batch(uuid[],text) to authenticated;
notify pgrst, 'reload schema';
