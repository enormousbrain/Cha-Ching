-- Run only in an empty disposable database. Reuse closeout fixtures and lock tests.
\ir allowance_settlements.sql
create function is_linked_child_profile(target_id uuid) returns boolean language sql stable as $$
  select exists(select 1 from child_profiles where id=target_id and linked_user_id=auth.uid())
$$;
create table chore_definitions(id uuid primary key, family_id uuid, verification_mode text, title text, deduction_cents integer);
create table family_evidence_policies(family_id uuid primary key, photo_evidence_enabled boolean);
create table chore_submissions(id uuid primary key default gen_random_uuid(), task_occurrence_id uuid,
  child_id uuid, image_path text, submitted_at timestamptz default now(), parent_decision jsonb);
alter table task_occurrences add column chore_definition_id uuid, add column child_id uuid,
  add column submission_id uuid, add column updated_at timestamptz, add column deduction_ledger_entry_id uuid,
  add column excuse_reason text;
alter table ledger_entries add column related_occurrence_id uuid;
\ir ../migrations/0005_parent_review_decisions.sql
\ir ../migrations/0022_catch_up_submissions.sql
insert into family_members values ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','child');

do $$
declare
  family uuid := '10000000-0000-0000-0000-000000000001';
  child uuid := '20000000-0000-0000-0000-000000000001';
  period uuid := '30000000-0000-0000-0000-000000000003';
  chore uuid := gen_random_uuid();
  task uuid := gen_random_uuid();
  photo_task uuid := gen_random_uuid();
  photo_id uuid := gen_random_uuid();
  first_submission uuid;
  second_submission uuid;
begin
  insert into chore_definitions values (chore,family,'none','Tidy desk',100);
  insert into task_occurrences(id,week_id,status,chore_definition_id,child_id)
    values (task,period,'missed',chore,child), (photo_task,period,'missed',chore,child);
  insert into ledger_entries(week_id,child_id,entry_type,amount_cents,related_occurrence_id)
    values (period,child,'deduction',100,task), (period,child,'deduction',100,photo_task);
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
  perform pg_temp.expect_error(format('select submit_chore_without_photo(%L)',task),'not_assigned_child');
  perform pg_temp.expect_error(format('select register_chore_photo_submission(%L,%L,%L)',photo_id,photo_task,family||'/proof.jpg'),'not_assigned_child');
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
  select submission_id into first_submission from submit_chore_without_photo(task);
  select submission_id into second_submission from submit_chore_without_photo(task);
  if first_submission is distinct from second_submission then raise exception 'duplicate no-photo submission'; end if;
  if (select status from task_occurrences where id=task) <> 'submitted' then raise exception 'late submission not queued'; end if;
  if exists(select 1 from ledger_entries where related_occurrence_id=task and is_voided) then raise exception 'deduction restored before review'; end if;
  perform register_chore_photo_submission(photo_id,photo_task,family||'/proof.jpg');
  perform register_chore_photo_submission(photo_id,photo_task,family||'/proof.jpg');
  if (select count(*) from chore_submissions where task_occurrence_id=photo_task) <> 1 then raise exception 'duplicate photo submission'; end if;
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
  perform decide_chore_submission(task,'approved');
  perform decide_chore_submission(task,'approved');
  if exists(select 1 from ledger_entries where related_occurrence_id=task and not is_voided) then raise exception 'approval did not restore deduction'; end if;
  perform decide_chore_submission(photo_task,'rejected');
  if (select count(*) from ledger_entries where related_occurrence_id=photo_task and not is_voided) <> 1 then raise exception 'rejection duplicated deduction'; end if;
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
  perform pg_temp.expect_error(format('select submit_chore_without_photo(%L)',task),'occurrence_not_open');
  perform pg_temp.expect_error(format('select submit_chore_without_photo(%L)',photo_task),'occurrence_not_open');
  -- A parent has settled this period; every subsequent submission must fail.
  insert into allowance_settlements(week_id,amount_cents,confirmed_by) values(period,1100,'00000000-0000-0000-0000-000000000001');
  perform pg_temp.expect_error(format('select submit_chore_without_photo(%L)',task),'allowance_period_confirmed');
  perform pg_temp.expect_error(format('select register_chore_photo_submission(%L,%L,%L)',photo_id,photo_task,family||'/proof.jpg'),'allowance_period_confirmed');
end $$;
select 'Catch-up ownership, photo/no-photo retries, parent approval/rejection and settled period checks passed' as result;
