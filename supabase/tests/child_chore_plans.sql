-- EMPTY disposable database only.
\ir initiative_stars.sql
\ir ../migrations/0026_child_chore_plans.sql
begin;
do $$
declare
  parent uuid:=gen_random_uuid(); kid uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  family uuid:=gen_random_uuid(); child uuid:=gen_random_uuid(); sibling uuid:=gen_random_uuid();
  period uuid:=gen_random_uuid(); chore uuid:=gen_random_uuid(); task uuid:=gen_random_uuid(); sibling_task uuid:=gen_random_uuid();
  first_created timestamptz;
begin
  insert into auth.users values(parent),(kid),(outsider);
  insert into families(id,name) values(family,'Plan test');
  insert into family_members(family_id,user_id,role,display_name) values(family,parent,'parent','Parent'),(family,kid,'child','Child');
  insert into child_profiles(id,family_id,display_name,linked_user_id) values(child,family,'Child',kid),(sibling,family,'Sibling',null);
  insert into weeks(id,family_id,child_id,starts_at,ends_at,base_allowance_cents) values(period,family,child,now()-interval '1 day',now()+interval '6 days',1500);
  insert into chore_definitions(id,family_id,child_id,title,short_title,deduction_cents,recurrence)
    values(chore,family,child,'Room','Room',100,'{"frequency":"daily"}');
  insert into task_occurrences(id,chore_definition_id,child_id,week_id,scheduled_at,due_at,expires_at,status)
    values(task,chore,child,period,now(),now()+interval '2 hours',now()+interval '3 hours','upcoming'),
      (sibling_task,chore,sibling,period,now()+interval '1 minute',now()+interval '2 hours',now()+interval '3 hours','upcoming');
  perform set_config('request.jwt.claim.sub',parent::text,true);
  perform pg_temp.expect_error(format('select set_child_chore_plan(%L,now())',task),'Only the assigned child');
  perform set_config('request.jwt.claim.sub',kid::text,true);
  perform pg_temp.expect_error(format('select set_child_chore_plan(%L,now())',sibling_task),'Only the assigned child');
  perform pg_temp.expect_error(format('select set_child_chore_plan(%L,now()-interval ''1 hour'')',task),'Choose a time');
  perform pg_temp.expect_error(format('select set_child_chore_plan(%L,now()+interval ''3 hours'')',task),'Choose a time');
  perform set_child_chore_plan(task,now()+interval '30 minutes');
  perform set_child_chore_plan(task,now()+interval '30 minutes');
  if (select count(*) from child_chore_plans where occurrence_id=task)<>1 then raise exception 'Duplicate plan'; end if;
  select created_at into first_created from child_chore_plans where occurrence_id=task;
  perform set_child_chore_plan(task,now()+interval '1 hour');
  if (select created_at from child_chore_plans where occurrence_id=task)<>first_created then raise exception 'Replanning changed creation time'; end if;
  if exists(select 1 from initiative_stars where child_id=child) then raise exception 'Choosing a plan earned a star'; end if;
  perform set_child_chore_plan(task,null);
  if not exists(select 1 from child_chore_plans where occurrence_id=task and cancelled_at is not null) then raise exception 'Plan not cleared'; end if;
  perform set_child_chore_plan(task,now()+interval '2 hours');
  if exists(select 1 from child_chore_plans where occurrence_id=task and cancelled_at is not null) then raise exception 'Plan not restored'; end if;
  set local role authenticated;
  if (select count(*) from child_chore_plans)<>1 then raise exception 'Child cannot read own plan'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  set local role authenticated;
  if exists(select 1 from child_chore_plans) then raise exception 'Outsider read plan'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub',parent::text,true);
  set local role authenticated;
  if (select count(*) from child_chore_plans)<>1 then raise exception 'Parent cannot see plan'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub',kid::text,true);
  update chore_definitions set is_paused=true where id=chore;
  perform pg_temp.expect_error(format('select set_child_chore_plan(%L,now())',task),'Choose a time');
  update chore_definitions set is_paused=false where id=chore;
  update task_occurrences set status='submitted' where id=task;
  perform pg_temp.expect_error(format('select set_child_chore_plan(%L,now())',task),'no longer available');
  update task_occurrences set status='upcoming' where id=task;
  insert into allowance_settlements(week_id,amount_cents,confirmed_by) values(period,1500,parent);
  perform pg_temp.expect_error(format('select set_child_chore_plan(%L,now())',task),'no longer available');
end $$;
set local role authenticated;
select pg_temp.expect_error('delete from public.child_chore_plans','permission denied');
reset role;
rollback;
