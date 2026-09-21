alter table public.child_profiles
  add column if not exists savings_goals jsonb not null default '[]'::jsonb;

create or replace function public.set_child_savings_goals(target_child_id uuid, goals jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  goal jsonb;
begin
  if auth.uid() is null or not public.is_linked_child_profile(target_child_id) then
    raise exception 'not_linked_child' using errcode = '42501';
  end if;
  if goals is null or jsonb_typeof(goals) <> 'array' then
    raise exception 'invalid_goals' using errcode = '22023';
  end if;
  if jsonb_array_length(goals) > 5 then
    raise exception 'too_many_goals' using errcode = '22023';
  end if;
  for goal in select value from jsonb_array_elements(goals) loop
    if jsonb_typeof(goal->'title') is distinct from 'string'
       or length(trim(goal->>'title')) not between 1 and 60
       or jsonb_typeof(goal->'targetCents') is distinct from 'number'
       or (goal->>'targetCents')::numeric not between 1 and 100000000
       or (goal->>'targetCents')::numeric <> trunc((goal->>'targetCents')::numeric)
       or goal->>'id' is null then
      raise exception 'invalid_goal' using errcode = '22023';
    end if;
    perform (goal->>'id')::uuid;
  end loop;
  if (select count(distinct value->>'id') from jsonb_array_elements(goals)) <> jsonb_array_length(goals) then
    raise exception 'duplicate_goal' using errcode = '22023';
  end if;
  update public.child_profiles set savings_goals = goals where id = target_child_id;
end;
$$;

revoke all on function public.set_child_savings_goals(uuid, jsonb) from public, anon;
grant execute on function public.set_child_savings_goals(uuid, jsonb) to authenticated;
