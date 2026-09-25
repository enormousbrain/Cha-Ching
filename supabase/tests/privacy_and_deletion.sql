-- Run only in an EMPTY, disposable database. Real schema with stubbed Auth/Storage services.
\set ON_ERROR_STOP on
do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end $$;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
create function auth.role() returns text language sql stable as $$ select current_setting('request.jwt.claim.role',true) $$;
create schema storage;
create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner_id text,
  created_at timestamptz default now(), updated_at timestamptz default now(), unique(bucket_id,name));
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$ select string_to_array(name,'/') $$;
grant usage on schema public,auth,storage to anon,authenticated,service_role;
grant all on storage.objects to authenticated,service_role;
\ir ../migrations/0001_initial_schema.sql
\ir ../migrations/0002_child_profiles_and_invites.sql
\ir ../migrations/0003_parent_invites.sql
\ir ../migrations/0004_family_bootstrap.sql
\ir ../migrations/0005_parent_review_decisions.sql
\ir ../migrations/0006_parent_settings_sync.sql
\ir ../migrations/0007_evidence_policy_settings.sql
\ir ../migrations/0008_task_nudges.sql
\ir ../migrations/0009_chore_recurrence.sql
\ir ../migrations/0010_task_deadlines.sql
\ir ../migrations/0011_chore_lifecycle.sql
\ir ../migrations/0012_evidence_deletion_schedule.sql
\ir ../migrations/0013_retention_cleanup.sql
\ir ../migrations/0014_submission_registration.sql
-- Migration 15/19 install hosted cron extensions; not needed by these tests.
\ir ../migrations/0016_child_excuse_requests.sql
\ir ../migrations/0017_savings_goals.sql
\ir ../migrations/0018_parent_overdue_alerts.sql
\ir ../migrations/0020_chore_locations.sql
\ir ../migrations/0021_allowance_settlements.sql
\ir ../migrations/0022_catch_up_submissions.sql
\ir ../migrations/0023_grouped_chore_claims.sql
\ir ../migrations/0024_privacy_and_account_deletion.sql

create function pg_temp.expect_error(statement text, expected text) returns void language plpgsql as $$
begin
  begin execute statement; exception when others then
    if position(expected in SQLERRM) > 0 then return; end if;
    raise;
  end;
  raise exception 'Expected failure: %', statement;
end $$;

do $$
declare
  p1 uuid := gen_random_uuid(); p2 uuid := gen_random_uuid(); kid uuid := gen_random_uuid();
  outsider uuid := gen_random_uuid(); family uuid := gen_random_uuid(); other_family uuid := gen_random_uuid();
  child uuid := gen_random_uuid(); sibling uuid := gen_random_uuid(); period uuid := gen_random_uuid();
  chore uuid := gen_random_uuid(); task uuid := gen_random_uuid(); submission uuid := gen_random_uuid();
  photo text; orphan text; recent text;
begin
  insert into auth.users values(p1),(p2),(kid),(outsider);
  insert into families(id,name) values(family,'Test family'),(other_family,'Other family');
  insert into family_members(family_id,user_id,role,display_name) values
    (family,p1,'parent','Parent one'),(family,p2,'parent','Parent two'),(family,kid,'child','Child'),(other_family,outsider,'parent','Other parent');
  insert into child_profiles(id,family_id,display_name,linked_user_id,created_by_parent_id) values
    (child,family,'Child',kid,p1),(sibling,family,'Sibling',null,p1);
  insert into weeks(id,family_id,child_id,starts_at,ends_at,base_allowance_cents)
    values(period,family,child,now()-interval '8 days',now()-interval '1 day',1500);
  insert into chore_definitions(id,family_id,child_id,title,short_title,deduction_cents,recurrence)
    values(chore,family,child,'Chore','Chore',100,'{}');
  insert into task_occurrences(id,chore_definition_id,child_id,week_id,scheduled_at,due_at,expires_at,status,excused_by_parent_id)
    values(task,chore,child,period,now(),now(),now(),'missed',p1);
  photo := family::text || '/' || task::text || '/' || submission::text || '.jpg';
  orphan := family::text || '/abandoned.jpg'; recent := family::text || '/recent.jpg';
  insert into storage.objects(bucket_id,name,owner_id,created_at,updated_at) values
    ('chore-evidence',photo,kid::text,now()-interval '2 days',now()-interval '2 days'),
    ('chore-evidence',orphan,kid::text,now()-interval '2 days',now()-interval '2 days'),
    ('chore-evidence',recent,kid::text,now(),now());

  perform set_config('request.jwt.claim.sub',kid::text,true);
  perform pg_temp.expect_error(format('select set_photo_sharing_consent(%L,true)',family),'parent must authorize');
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  perform pg_temp.expect_error(format('select set_photo_sharing_consent(%L,true)',family),'Family membership required');
  perform set_config('request.jwt.claim.sub',p1::text,true);
  perform set_photo_sharing_consent(family,true);
  perform set_config('request.jwt.claim.sub',kid::text,true);
  if can_share_chore_photo(family) then raise exception 'child consent bypassed'; end if;
  execute 'set local role authenticated';
  perform pg_temp.expect_error(format('insert into storage.objects(bucket_id,name) values(%L,%L)', 'chore-evidence', family::text || '/' || task::text || '/blocked.jpg'), 'row-level security');
  execute 'reset role';
  perform set_photo_sharing_consent(family,true);
  if not can_share_chore_photo(family) then raise exception 'consent not effective'; end if;
  if can_upload_chore_photo(other_family::text || '/' || task::text || '/wrong.jpg') then raise exception 'cross-family upload allowed'; end if;
  execute 'set local role authenticated';
  perform pg_temp.expect_error(format('select prepare_account_deletion(%L)',p1), 'permission denied');
  perform pg_temp.expect_error('select * from evidence_removal_queue', 'permission denied');
  execute 'reset role';
  insert into chore_submissions(id,task_occurrence_id,child_id,image_path,parent_decision)
    values(submission,task,child,photo,jsonb_build_object('parent_id',p1::text,'decision','approved'));
  update task_occurrences set submission_id = submission where id = task;
  if queue_orphaned_evidence() <> 1 then raise exception 'orphan queue selected registered or fresh upload'; end if;
  if exists(select 1 from evidence_removal_queue where path = photo or path = recent) then raise exception 'active photo queued'; end if;
  perform pg_temp.expect_error(format('insert into chore_submissions(task_occurrence_id,child_id,image_path) values(%L,%L,%L)',task,child,orphan),'Photo expired');
  perform set_config('request.jwt.claim.sub',p1::text,true);
  perform set_photo_sharing_consent(family,false);
  perform set_config('request.jwt.claim.sub',kid::text,true);
  if can_share_chore_photo(family) then raise exception 'withdrawal ineffective'; end if;
  perform pg_temp.expect_error(format('insert into chore_submissions(task_occurrence_id,child_id,image_path) values(%L,%L,%L)',task,child,recent),'consent required');

  insert into ledger_entries(week_id,child_id,created_by,entry_type,title,amount_cents)
    values(period,child,p1,'bonus','Bonus',100);
  insert into allowance_settlements(week_id,amount_cents,confirmed_by,paid_at,paid_by) values(period,1600,p1,now(),p1);
  perform set_config('request.jwt.claim.role','service_role',true);
  perform prepare_account_deletion(p1);
  perform prepare_account_deletion(p1);
  if not exists(select 1 from families where id = family) then raise exception 'co-parent lost family'; end if;
  if not exists(select 1 from child_profiles where id = child) then raise exception 'co-parent lost child'; end if;
  if exists(select 1 from allowance_settlements where confirmed_by = p1 or paid_by = p1) then raise exception 'attribution retained'; end if;
  if (select parent_decision ? 'parent_id' from chore_submissions where id = submission) then raise exception 'decision attribution retained'; end if;
  if not exists(select 1 from allowance_settlements where week_id = period and paid_at is not null and amount_cents=1600) then raise exception 'shared settlement changed'; end if;
  perform pg_temp.expect_error(format('insert into family_members(family_id,user_id,role,display_name) values(%L,%L,%L,%L)',family,p1,'parent','Again'),'deletion is in progress');
  perform pg_temp.expect_error(format('update ledger_entries set amount_cents=500 where week_id=%L',period),'confirmed and cannot');

  perform prepare_account_deletion(kid);
  if exists(select 1 from child_profiles where id=child) or exists(select 1 from chore_submissions where id=submission) then raise exception 'child data retained'; end if;
  if not exists(select 1 from child_profiles where id=sibling) then raise exception 'sibling data erased'; end if;
  if (select count(*) from evidence_removal_queue where deletion_user_id=kid) <> 3 then raise exception 'photos not durably queued'; end if;
  perform prepare_account_deletion(p2);
  if exists(select 1 from families where id=family) or exists(select 1 from child_profiles where id=sibling) then raise exception 'last-parent family retained'; end if;
  if not exists(select 1 from families where id=other_family) then raise exception 'other family erased'; end if;
  if has_function_privilege('authenticated','prepare_account_deletion(uuid)','execute') or
     has_function_privilege('anon','queue_orphaned_evidence(integer)','execute') then raise exception 'privileged cleanup exposed'; end if;
end $$;
select 'Privacy consent, orphan exclusion, retries, child isolation, co-parent retention and last-parent deletion passed' as result;
