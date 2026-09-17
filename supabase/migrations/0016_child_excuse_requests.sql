create or replace function public.request_chore_excuse(
  target_occurrence_id uuid,
  target_reason text default 'Child asked for a parent check.'
)
returns table (
  occurrence_id uuid,
  status text,
  excuse_reason text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  occurrence_record public.task_occurrences%rowtype;
  linked_child_user_id uuid;
  normalized_reason text := coalesce(nullif(trim(target_reason), ''), 'Child asked for a parent check.');
begin
  if current_user_id is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  select task_occurrences.*
  into occurrence_record
  from public.task_occurrences
  where task_occurrences.id = target_occurrence_id
  for update;

  if occurrence_record.id is null then
    raise exception 'occurrence_not_found' using errcode = 'P0002';
  end if;

  select child_profiles.linked_user_id
  into linked_child_user_id
  from public.child_profiles
  where child_profiles.id = occurrence_record.child_id;

  if linked_child_user_id is distinct from current_user_id then
    raise exception 'not_linked_child' using errcode = '42501';
  end if;

  if occurrence_record.status not in ('upcoming', 'due', 'submitted') then
    raise exception 'occurrence_not_open' using errcode = '22023';
  end if;

  update public.task_occurrences
  set
    status = 'submitted',
    excuse_reason = normalized_reason,
    updated_at = now()
  where id = target_occurrence_id;

  return query
  select target_occurrence_id, 'submitted'::text, normalized_reason;
end;
$$;

revoke all on function public.request_chore_excuse(uuid, text) from public, anon;
grant execute on function public.request_chore_excuse(uuid, text) to authenticated;
