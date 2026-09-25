-- EMPTY disposable database only. Reuse the Auth/Storage stubs and full schema.
\ir privacy_and_deletion.sql
\ir ../migrations/0025_initiative_stars.sql
-- Supabase's default table grants are not present in the disposable PostgreSQL fixture.
grant select on public.child_profiles to authenticated;
begin;
do $$
declare
  parent uuid:=gen_random_uuid(); kid uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  family uuid:=gen_random_uuid(); child uuid:=gen_random_uuid(); sibling uuid:=gen_random_uuid();
  period uuid:=gen_random_uuid(); chore uuid:=gen_random_uuid(); task uuid:=gen_random_uuid();
  task2 uuid:=gen_random_uuid(); task3 uuid:=gen_random_uuid(); task4 uuid:=gen_random_uuid();
  award uuid:=gen_random_uuid(); request uuid:=gen_random_uuid(); request2 uuid:=gen_random_uuid(); request3 uuid:=gen_random_uuid();
begin
  insert into auth.users values(parent),(kid),(outsider);
  insert into families(id,name) values(family,'Stars test');
  insert into family_members(family_id,user_id,role,display_name) values(family,parent,'parent','Parent'),(family,kid,'child','Child');
  insert into child_profiles(id,family_id,display_name,linked_user_id) values(child,family,'Child',kid),(sibling,family,'Sibling',null);
  insert into weeks(id,family_id,child_id,starts_at,ends_at,base_allowance_cents) values(period,family,child,now()-interval '2 days',now()+interval '5 days',1500);
  insert into chore_definitions(id,family_id,child_id,title,short_title,deduction_cents,recurrence)
    values(chore,family,child,'Room','Room',100,'{"frequency":"daily"}');
  insert into task_occurrences(id,chore_definition_id,child_id,week_id,scheduled_at,due_at,expires_at,status)
    values(task,chore,child,period,now()-interval '1 day',now()-interval '1 day',now()-interval '22 hours','missed'),
      (task2,chore,child,period,now()-interval '2 days',now()-interval '2 days',now()-interval '46 hours','missed');
  insert into ledger_entries(week_id,child_id,entry_type,title,amount_cents,related_occurrence_id)
    values(period,child,'deduction','Missed room',100,task),(period,child,'deduction','Missed room',100,task2);
  perform set_config('request.jwt.claim.sub',kid::text,true);
  perform pg_temp.expect_error(format('select award_initiative_star(%L,%L,%L)',award,child,'Noticed a need'),'Only a family parent');
  perform pg_temp.expect_error(format('select request_star_credit(%L,%L)',request,task),'Five stars');
  perform set_config('request.jwt.claim.sub',parent::text,true);
  perform award_initiative_star(award,child,'Noticed a need');
  perform award_initiative_star(award,child,'Noticed a need');
  if initiative_star_balance(child)<>1 then raise exception 'Award retry duplicated'; end if;
  perform pg_temp.expect_error(format('select award_initiative_star(%L,%L,%L)',award,child,'Different reason'),'already been used');
  perform pg_temp.expect_error(format('select award_initiative_star(%L,%L,%L,%L)',gen_random_uuid(),child,'Early',task),'Review and approve');
  for i in 1..4 loop perform award_initiative_star(gen_random_uuid(),child,'Made a plan'); end loop;
  perform set_config('request.jwt.claim.sub',kid::text,true);
  perform pg_temp.expect_error(format('select initiative_star_balance(%L)',sibling),'not available');
  perform request_star_credit(request,task);
  perform request_star_credit(request,task);
  perform request_star_credit(request2,task2);
  if (select count(*) from star_credit_requests where occurrence_id=task)<>1 then raise exception 'Request retry duplicated'; end if;
  perform pg_temp.expect_error(format('select decide_star_credit(%L,true)',request),'Only a family parent');
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  perform pg_temp.expect_error(format('select initiative_star_balance(%L)',child),'not available');
  perform pg_temp.expect_error(format('select decide_star_credit(%L,true)',request),'Only a family parent');
  perform set_config('request.jwt.claim.sub',parent::text,true);
  perform decide_star_credit(request,true);
  perform decide_star_credit(request,true);
  if initiative_star_balance(child)<>0 then raise exception 'Credit retry spent twice'; end if;
  if (select status from task_occurrences where id=task)<>'missed' then raise exception 'Credit changed completion'; end if;
  if exists(select 1 from ledger_entries where related_occurrence_id=task and not is_voided) then raise exception 'Deduction not cleared'; end if;
  perform pg_temp.expect_error(format('select decide_star_credit(%L,true)',request2),'Not enough stars');
  perform decide_star_credit(request2,false);
  if initiative_star_balance(child)<>0 then raise exception 'Decline spent stars'; end if;
  if not exists(select 1 from ledger_entries where related_occurrence_id=task2 and not is_voided) then raise exception 'Decline cleared deduction'; end if;
  -- One approved occurrence can earn only one star, even with different request IDs.
  update task_occurrences set status='approved' where id=task2;
  perform award_initiative_star(gen_random_uuid(),child,'Prepared ahead',task2);
  perform pg_temp.expect_error(format('select award_initiative_star(%L,%L,%L,%L)',gen_random_uuid(),child,'Prepared ahead',task2),'already earned');
  perform award_initiative_star(gen_random_uuid(),sibling,'Independent planning');
  perform set_config('request.jwt.claim.sub',kid::text,true);
  set local role authenticated;
  if exists(select 1 from initiative_stars where child_id<>child) then raise exception 'Child read another child stars'; end if;
  if not exists(select 1 from initiative_stars where child_id=child) then raise exception 'Child cannot read own stars'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  set local role authenticated;
  if exists(select 1 from initiative_stars) or exists(select 1 from star_credit_requests) then raise exception 'Outsider read family rewards'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub',parent::text,true);
  for i in 1..4 loop perform award_initiative_star(gen_random_uuid(),child,'Followed a plan'); end loop;
  insert into task_occurrences(id,chore_definition_id,child_id,week_id,scheduled_at,due_at,expires_at,status)
    values(task3,chore,child,period,now()-interval '3 days',now()-interval '3 days',now()-interval '70 hours','missed'),
      (task4,chore,child,period,now()-interval '4 days',now()-interval '4 days',now()-interval '94 hours','missed');
  insert into ledger_entries(week_id,child_id,entry_type,title,amount_cents,related_occurrence_id)
    values(period,child,'deduction','Missed',100,task3),(period,child,'deduction','Missed',100,task4);
  perform request_star_credit(request3,task3);
  insert into allowance_settlements(week_id,amount_cents,confirmed_by) values(period,1100,parent);
  perform pg_temp.expect_error(format('select decide_star_credit(%L,true)',request3),'period is confirmed');
  perform pg_temp.expect_error(format('select request_star_credit(%L,%L)',gen_random_uuid(),task4),'unconfirmed');
  if initiative_star_balance(child)<>5 then raise exception 'Failed approval spent stars'; end if;
end $$;

-- Direct writes are unavailable to authenticated users; table reads remain RLS scoped.
set local role authenticated;
select pg_temp.expect_error('insert into public.initiative_stars(id,child_id,amount,reason) values(gen_random_uuid(),gen_random_uuid(),1,''cheat'')','permission denied');
reset role;
rollback;
