-- Exercises a linked profile without retaining any changes.
begin;
do $$
declare
  profile public.child_profiles%rowtype;
  goal jsonb := jsonb_build_array(jsonb_build_object(
    'id', gen_random_uuid(), 'title', 'Test bike', 'targetCents', 15000));
begin
  select * into profile from public.child_profiles where linked_user_id is not null limit 1;
  if profile.id is null then raise exception 'A linked child is required for this test'; end if;
  perform set_config('request.jwt.claim.sub', profile.linked_user_id::text, true);
  perform public.set_child_savings_goals(profile.id, goal);
  if (select savings_goals from public.child_profiles where id = profile.id) <> goal then
    raise exception 'Goal save failed';
  end if;
  begin
    perform public.set_child_savings_goals(profile.id,
      jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'title', 'Bike', 'targetCents', -1)));
    raise exception 'Invalid amount accepted';
  exception when sqlstate '22023' then null;
  end;
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  begin
    perform public.set_child_savings_goals(profile.id, '[]'::jsonb);
    raise exception 'Unrelated user accepted';
  exception when insufficient_privilege then null;
  end;
end;
$$;
rollback;
