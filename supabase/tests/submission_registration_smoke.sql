\set ON_ERROR_STOP on

begin;

do $$
declare
  child_user_id uuid;
  unauthorized_user_id uuid := gen_random_uuid();
  test_family_id uuid;
  child_profile_id uuid;
  chore_id uuid;
  week_id uuid;
  photo_occurrence_id uuid := gen_random_uuid();
  no_photo_occurrence_id uuid := gen_random_uuid();
  photo_submission_id uuid := gen_random_uuid();
  registered_submission_id uuid;
  registered_status text;
begin
  select
    parent_members.user_id,
    child_profiles.family_id,
    child_profiles.id,
    chore_definitions.id,
    weeks.id
  into
    child_user_id,
    test_family_id,
    child_profile_id,
    chore_id,
    week_id
  from public.child_profiles
  join public.chore_definitions
    on chore_definitions.family_id = child_profiles.family_id
   and chore_definitions.child_id = child_profiles.id
  join public.weeks
    on weeks.family_id = child_profiles.family_id
   and weeks.child_id = child_profiles.id
  join public.family_members as parent_members
    on parent_members.family_id = child_profiles.family_id
   and parent_members.role = 'parent'
  limit 1;

  if child_user_id is null then
    raise exception 'rollback_smoke_fixture_not_found';
  end if;

  update public.child_profiles
  set linked_user_id = child_user_id
  where id = child_profile_id;

  update public.family_members as membership
  set role = 'child'
  where membership.family_id = test_family_id
    and membership.user_id = child_user_id;

  update public.chore_definitions
  set verification_mode = 'photo_optional'
  where id = chore_id;

  insert into public.task_occurrences (
    id,
    chore_definition_id,
    child_id,
    week_id,
    scheduled_at,
    due_at,
    expires_at,
    status
  )
  values
    (
      photo_occurrence_id,
      chore_id,
      child_profile_id,
      week_id,
      now() + interval '200 years',
      now() + interval '200 years 1 hour',
      now() + interval '200 years 2 hours',
      'due'
    ),
    (
      no_photo_occurrence_id,
      chore_id,
      child_profile_id,
      week_id,
      now() + interval '200 years 1 day',
      now() + interval '200 years 1 day 1 hour',
      now() + interval '200 years 1 day 2 hours',
      'due'
    );

  perform set_config('request.jwt.claim.sub', unauthorized_user_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  begin
    perform *
    from public.register_chore_photo_submission(
      photo_submission_id,
      photo_occurrence_id,
      upper(test_family_id::text) || '/rollback-smoke/evidence.jpg'
    );
    raise exception 'unauthorized_registration_should_have_failed';
  exception
    when insufficient_privilege then
      null;
  end;

  perform set_config('request.jwt.claim.sub', child_user_id::text, true);

  select submission_id, status
  into registered_submission_id, registered_status
  from public.register_chore_photo_submission(
    photo_submission_id,
    photo_occurrence_id,
    upper(test_family_id::text) || '/rollback-smoke/evidence.jpg'
  );

  if registered_submission_id <> photo_submission_id or registered_status <> 'submitted' then
    raise exception 'photo_registration_failed';
  end if;

  select submission_id, status
  into registered_submission_id, registered_status
  from public.submit_chore_without_photo(no_photo_occurrence_id);

  if registered_submission_id is null or registered_status <> 'submitted' then
    raise exception 'no_photo_registration_failed';
  end if;
end;
$$;

select 'submission_registration_smoke_test=ok' as result;

rollback;
