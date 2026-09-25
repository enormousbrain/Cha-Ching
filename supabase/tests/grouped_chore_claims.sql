-- Empty disposable database only; reuse catch-up and closeout fixtures.
\ir catch_up_submissions.sql
\ir ../migrations/0023_grouped_chore_claims.sql
do $$
declare
  family uuid := '10000000-0000-0000-0000-000000000001';
  child uuid := '20000000-0000-0000-0000-000000000001';
  period uuid := gen_random_uuid();
  chore uuid := gen_random_uuid();
  tasks uuid[] := array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];
  stale uuid := gen_random_uuid();
  t uuid;
begin
  insert into weeks(id,family_id,child_id,starts_at,ends_at,base_allowance_cents) values(period,family,child,now(),now()+interval '7 days',1500);
  insert into chore_definitions values(chore,family,'photo_required','Walk dog',100);
  foreach t in array tasks loop
    insert into task_occurrences(id,week_id,status,chore_definition_id,child_id) values(t,period,'missed',chore,child);
    insert into ledger_entries(week_id,child_id,entry_type,amount_cents,related_occurrence_id) values(period,child,'deduction',100,t);
  end loop;
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
  perform pg_temp.expect_error(format('select report_chores_done(%L::uuid[],%L)',tasks,'Forgot photo'),'Only the assigned child');
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
  perform pg_temp.expect_error(format('select submit_chore_without_photo(%L)',tasks[1]),'photo_evidence_required');
  perform report_chores_done(tasks,'Forgot photo');
  perform report_chores_done(tasks,'Forgot photo');
  if (select count(*) from chore_submissions where task_occurrence_id=any(tasks)) <> 3 then raise exception 'duplicate claims'; end if;
  if (select count(*) from chore_submissions where task_occurrence_id=any(tasks) and reported_done_note='Forgot photo') <> 3 then raise exception 'notes lost'; end if;
  if exists(select 1 from ledger_entries where related_occurrence_id=any(tasks) and is_voided) then raise exception 'child restored deductions'; end if;
  perform pg_temp.expect_error(format('select review_chore_batch(%L::uuid[],%L)',tasks,'approved'),'Only a family parent');
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
  perform pg_temp.expect_error(format('select review_chore_batch(%L::uuid[],%L)',tasks,'approved'),'Only a family parent');
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
  perform review_chore_batch(tasks[1:2],'approved');
  if (select count(*) from ledger_entries where related_occurrence_id=any(tasks[1:2]) and is_voided) <> 2 then raise exception 'bulk approval did not restore deductions'; end if;
  perform pg_temp.expect_error(format('select review_chore_batch(%L::uuid[],%L)',tasks,'approved'),'already been reviewed');
  if (select status from task_occurrences where id=tasks[3]) <> 'submitted' then raise exception 'partial bulk decision'; end if;
  perform review_chore_batch(tasks[3:3],'rejected');
  if (select count(*) from ledger_entries where related_occurrence_id=tasks[3] and not is_voided) <> 1 then raise exception 'rejection duplicated deduction'; end if;
  -- One stale item must roll back otherwise eligible claims in the same batch.
  insert into task_occurrences(id,week_id,status,chore_definition_id,child_id) values(stale,period,'missed',chore,child);
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
  perform pg_temp.expect_error(format('select report_chores_done(%L::uuid[],%L)',array[stale,tasks[1]],''),'already been submitted or reviewed');
  if exists(select 1 from chore_submissions where task_occurrence_id=stale) then raise exception 'partial claim persisted'; end if;
  perform pg_temp.expect_error(format('select report_chores_done(%L::uuid[],%L)',array[stale,stale],''),'selection changed');
  insert into allowance_settlements(week_id,amount_cents,confirmed_by) values(period,1400,'00000000-0000-0000-0000-000000000001');
  perform pg_temp.expect_error(format('select report_chores_done(%L::uuid[],%L)',array[stale],''),'already confirmed');
end $$;
set role anon;
select pg_temp.expect_error($q$select report_chores_done(array[]::uuid[],'')$q$,'permission denied');
reset role;
select 'Grouped no-photo claims, retries, permissions, approvals, rejection, atomic rollback and locks passed' as result;
