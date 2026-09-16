create or replace function public.register_chore_photo_submission(
  target_submission_id uuid,
  target_occurrence_id uuid,
  target_image_path text
)
returns table (
  submission_id uuid,
  task_occurrence_id uuid,
  status text,
  submitted_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  occurrence_record public.task_occurrences%rowtype;
  chore_record public.chore_definitions%rowtype;
  submission_record public.chore_submissions%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  select *
  into occurrence_record
  from public.task_occurrences
  where id = target_occurrence_id
  for update;

  if not found then
    raise exception 'occurrence_not_found' using errcode = 'P0002';
  end if;

  if occurrence_record.status not in ('upcoming', 'due', 'submitted', 'ai_reviewed') then
    raise exception 'occurrence_not_open' using errcode = '22023';
  end if;

  select *
  into chore_record
  from public.chore_definitions
  where id = occurrence_record.chore_definition_id;

  if chore_record.id is null then
    raise exception 'chore_not_found' using errcode = 'P0002';
  end if;

  if not public.is_linked_child_profile(occurrence_record.child_id) or
     not exists (
       select 1
       from public.family_members
       where family_id = chore_record.family_id
         and user_id = auth.uid()
         and role = 'child'
     ) then
    raise exception 'not_assigned_child' using errcode = '42501';
  end if;

  if target_image_path is null or target_image_path = '' or
     not lower(target_image_path) like chore_record.family_id::text || '/%' then
    raise exception 'invalid_evidence_path' using errcode = '22023';
  end if;

  select *
  into submission_record
  from public.chore_submissions
  where id = target_submission_id;

  if submission_record.id is null then
    insert into public.chore_submissions (
      id,
      task_occurrence_id,
      child_id,
      image_path
    )
    values (
      target_submission_id,
      occurrence_record.id,
      occurrence_record.child_id,
      target_image_path
    )
    returning * into submission_record;
  elsif submission_record.task_occurrence_id <> occurrence_record.id or
        submission_record.child_id <> occurrence_record.child_id or
        submission_record.image_path is distinct from target_image_path then
    raise exception 'submission_id_conflict' using errcode = '23505';
  end if;

  update public.task_occurrences
  set
    submission_id = submission_record.id,
    status = 'submitted',
    updated_at = now()
  where id = occurrence_record.id;

  submission_id := submission_record.id;
  task_occurrence_id := occurrence_record.id;
  status := 'submitted';
  submitted_at := submission_record.submitted_at;
  return next;
end;
$$;

revoke all on function public.register_chore_photo_submission(uuid, uuid, text)
  from public, anon;
grant execute on function public.register_chore_photo_submission(uuid, uuid, text)
  to authenticated;

create or replace function public.submit_chore_without_photo(target_occurrence_id uuid)
returns table (
  submission_id uuid,
  task_occurrence_id uuid,
  status text,
  submitted_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  occurrence_record public.task_occurrences%rowtype;
  chore_record public.chore_definitions%rowtype;
  policy_record public.family_evidence_policies%rowtype;
  submission_record public.chore_submissions%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  select *
  into occurrence_record
  from public.task_occurrences
  where id = target_occurrence_id
  for update;

  if not found then
    raise exception 'occurrence_not_found' using errcode = 'P0002';
  end if;

  select *
  into chore_record
  from public.chore_definitions
  where id = occurrence_record.chore_definition_id;

  if chore_record.id is null then
    raise exception 'chore_not_found' using errcode = 'P0002';
  end if;

  if not public.is_linked_child_profile(occurrence_record.child_id) or
     not exists (
       select 1
       from public.family_members
       where family_id = chore_record.family_id
         and user_id = auth.uid()
         and role = 'child'
     ) then
    raise exception 'not_assigned_child' using errcode = '42501';
  end if;

  select *
  into policy_record
  from public.family_evidence_policies
  where family_id = chore_record.family_id;

  if coalesce(policy_record.photo_evidence_enabled, true) and
     chore_record.verification_mode = 'photo_required' then
    raise exception 'photo_evidence_required' using errcode = '22023';
  end if;

  if occurrence_record.submission_id is not null then
    select *
    into submission_record
    from public.chore_submissions
    where id = occurrence_record.submission_id;

    submission_id := submission_record.id;
    task_occurrence_id := occurrence_record.id;
    status := occurrence_record.status;
    submitted_at := submission_record.submitted_at;
    return next;
    return;
  end if;

  insert into public.chore_submissions (
    task_occurrence_id,
    child_id,
    image_path
  )
  values (
    occurrence_record.id,
    occurrence_record.child_id,
    null
  )
  returning * into submission_record;

  update public.task_occurrences
  set
    submission_id = submission_record.id,
    status = 'submitted',
    updated_at = now()
  where id = occurrence_record.id;

  submission_id := submission_record.id;
  task_occurrence_id := occurrence_record.id;
  status := 'submitted';
  submitted_at := submission_record.submitted_at;
  return next;
end;
$$;

revoke all on function public.submit_chore_without_photo(uuid) from public, anon;
grant execute on function public.submit_chore_without_photo(uuid) to authenticated;
