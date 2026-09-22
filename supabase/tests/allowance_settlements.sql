-- Run only against an empty disposable PostgreSQL database.
\set ON_ERROR_STOP on
do $$ begin
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon; end if;
end $$;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to authenticated, anon;
create table families(id uuid primary key, weekly_base_allowance_cents integer not null);
create table family_members(family_id uuid, user_id uuid, role text);
create function is_family_parent(target_family_id uuid) returns boolean language sql stable security definer as $$
  select exists(select 1 from family_members where family_id = target_family_id and user_id = auth.uid() and role = 'parent')
$$;
create table child_profiles(id uuid primary key, family_id uuid, linked_user_id uuid);
create table weeks(id uuid primary key, family_id uuid, child_id uuid, starts_at timestamptz, ends_at timestamptz,
  archived_at timestamptz, base_allowance_cents integer, final_balance_cents integer);
create table ledger_entries(id uuid primary key default gen_random_uuid(), week_id uuid references weeks(id) on delete cascade,
  child_id uuid, created_by uuid, entry_type text, title text, amount_cents integer, note text, is_voided boolean default false);
create table task_occurrences(id uuid primary key default gen_random_uuid(), week_id uuid references weeks(id) on delete cascade, status text);
grant select on weeks, child_profiles to authenticated;

\ir ../migrations/0021_allowance_settlements.sql

insert into auth.users values ('00000000-0000-0000-0000-000000000001'), ('00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000003'), ('00000000-0000-0000-0000-000000000004');
insert into families values ('10000000-0000-0000-0000-000000000001',1500), ('10000000-0000-0000-0000-000000000002',1500);
insert into family_members values ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','parent'),
  ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000004','parent');
insert into child_profiles values ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002'),
  ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000003');
insert into weeks(id,family_id,child_id,starts_at,ends_at,base_allowance_cents) values
  ('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',now()-interval '14 days',now()-interval '7 days',1500),
  ('30000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',now()-interval '7 days',now()+interval '1 day',1000);
insert into ledger_entries(week_id,entry_type,amount_cents) values
  ('30000000-0000-0000-0000-000000000001','weekly_base',1500),
  ('30000000-0000-0000-0000-000000000001','deduction',2000),
  ('30000000-0000-0000-0000-000000000002','weekly_base',1000);
update weeks set archived_at = now()-interval '7 days', final_balance_cents=0 where id='30000000-0000-0000-0000-000000000001';
insert into task_occurrences(week_id,status) values ('30000000-0000-0000-0000-000000000001','submitted');

create function pg_temp.expect_error(statement text, expected text) returns void language plpgsql as $$
begin
  begin execute statement; exception when others then
    if position(expected in SQLERRM) > 0 then return; end if;
    raise;
  end;
  raise exception 'Expected failure: %', statement;
end;
$$;
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
select pg_temp.expect_error($q$select confirm_allowance_period('30000000-0000-0000-0000-000000000001',0)$q$, 'Only a family parent');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
select pg_temp.expect_error($q$select confirm_allowance_period('30000000-0000-0000-0000-000000000001',0)$q$, 'Only a family parent');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select pg_temp.expect_error($q$select mark_allowance_paid('30000000-0000-0000-0000-000000000001')$q$, 'Confirm this allowance');
select pg_temp.expect_error($q$select confirm_allowance_period('30000000-0000-0000-0000-000000000002',1000)$q$, 'Wait until');
select pg_temp.expect_error($q$select confirm_allowance_period('30000000-0000-0000-0000-000000000001',0)$q$, 'Resolve all pending');
reset role;
-- A late approval removes a deduction, releasing the $5 already carried forward.
update task_occurrences set status='approved';
update ledger_entries set is_voided=true where week_id='30000000-0000-0000-0000-000000000001' and entry_type='deduction';
set role authenticated;
select pg_temp.expect_error($q$select confirm_allowance_period('30000000-0000-0000-0000-000000000001',0)$q$, 'amount changed');
select * from confirm_allowance_period('30000000-0000-0000-0000-000000000001',1500);
select * from confirm_allowance_period('30000000-0000-0000-0000-000000000001',1500);
select pg_temp.expect_error($q$update allowance_settlements set amount_cents=9999$q$, 'permission denied');
reset role;
do $$ begin
  if (select count(*) from allowance_settlements) <> 1 then raise exception 'duplicate settlement'; end if;
  if (select sum(amount_cents) from ledger_entries where week_id='30000000-0000-0000-0000-000000000002') <> 1500 then raise exception 'incorrect carryover reconciliation'; end if;
end $$;
select pg_temp.expect_error($q$update ledger_entries set amount_cents=9999 where week_id='30000000-0000-0000-0000-000000000001'$q$, 'confirmed and cannot');
select pg_temp.expect_error($q$delete from task_occurrences where week_id='30000000-0000-0000-0000-000000000001'$q$, 'confirmed and cannot');
select pg_temp.expect_error($q$update task_occurrences set status='submitted'$q$, 'confirmed and cannot');
set role authenticated;
select * from mark_allowance_paid('30000000-0000-0000-0000-000000000001');
select * from mark_allowance_paid('30000000-0000-0000-0000-000000000001');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
do $$ begin if (select count(*) from allowance_settlements) <> 1 then raise exception 'child cannot read own settlement'; end if; end $$;
select pg_temp.expect_error($q$select mark_allowance_paid('30000000-0000-0000-0000-000000000001')$q$, 'Only a family parent');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
do $$ begin if (select count(*) from allowance_settlements) <> 0 then raise exception 'sibling can read settlement'; end if; end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
do $$ begin if (select count(*) from allowance_settlements) <> 0 then raise exception 'other family can read settlement'; end if; end $$;
reset role;
select 'Settlement permissions, pending reviews, stale amounts, late approval, locks, and retry checks passed' as result;

-- A later period acquires debt after rollover; it must reduce the following period once.
insert into weeks(id,family_id,child_id,starts_at,ends_at,base_allowance_cents) values
 ('30000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',now()+interval '1 day',now()+interval '8 days',1500);
insert into ledger_entries(week_id,entry_type,amount_cents) values ('30000000-0000-0000-0000-000000000003','weekly_base',1500);
update weeks set ends_at=now()-interval '1 minute', archived_at=now(), final_balance_cents=1500
 where id='30000000-0000-0000-0000-000000000002';
insert into ledger_entries(week_id,entry_type,amount_cents) values ('30000000-0000-0000-0000-000000000002','deduction',1800);
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select * from confirm_allowance_period('30000000-0000-0000-0000-000000000002',0);
select * from confirm_allowance_period('30000000-0000-0000-0000-000000000002',0);
select * from mark_allowance_paid('30000000-0000-0000-0000-000000000002');
reset role;
do $$ begin
 if (select sum(case when entry_type='deduction' then -amount_cents else amount_cents end) from ledger_entries
   where week_id='30000000-0000-0000-0000-000000000003' and not is_voided) <> 1200 then raise exception 'late rejection carryover incorrect'; end if;
end $$;
set role anon;
select pg_temp.expect_error($q$select * from allowance_settlements$q$, 'permission denied');
select pg_temp.expect_error($q$select mark_allowance_paid('30000000-0000-0000-0000-000000000001')$q$, 'permission denied');
reset role;
select 'Late rejection, zero closeout and anonymous access checks passed' as result;
