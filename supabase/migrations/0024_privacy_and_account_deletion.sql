-- Consent and deletion work are server-owned, including retries after a device disconnects.
create table public.photo_sharing_consents (
  family_id uuid not null references public.families(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  version integer not null default 1 check (version = 1),
  accepted_at timestamptz not null default now(),
  primary key (family_id, user_id)
);
alter table public.photo_sharing_consents enable row level security;
revoke all on public.photo_sharing_consents from anon, authenticated;

create table public.account_deletion_requests (
  user_id uuid primary key,
  requested_at timestamptz not null default now(),
  attempted_at timestamptz
);
create table public.evidence_removal_queue (
  path text primary key,
  deletion_user_id uuid,
  queued_at timestamptz not null default now(),
  attempted_at timestamptz
);
create index evidence_removal_queue_user_idx on public.evidence_removal_queue(deletion_user_id);
create index chore_submissions_image_path_idx on public.chore_submissions(image_path) where image_path is not null;
create index chore_submissions_thumbnail_path_idx on public.chore_submissions(thumbnail_path) where thumbnail_path is not null;
alter table public.account_deletion_requests enable row level security;
alter table public.evidence_removal_queue enable row level security;
revoke all on public.account_deletion_requests, public.evidence_removal_queue from anon, authenticated;
grant all on public.account_deletion_requests, public.evidence_removal_queue to service_role;

create function public.photo_sharing_status(target_family_id uuid)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'familyAuthorized', public.is_family_member(target_family_id) and exists (
      select 1 from photo_sharing_consents c join family_members m
      on m.family_id = c.family_id and m.user_id = c.user_id
      where c.family_id = target_family_id and m.role = 'parent'),
    'userAccepted', exists(select 1 from photo_sharing_consents
      where family_id = target_family_id and user_id = auth.uid())
  );
$$;
create function public.set_photo_sharing_consent(target_family_id uuid, accepted boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform 1 from families where id = target_family_id for update;
  if not public.is_family_member(target_family_id) or exists (
    select 1 from account_deletion_requests where user_id = auth.uid()) then
    raise exception 'Family membership required' using errcode = '42501';
  end if;
  if accepted then
    if not public.is_family_parent(target_family_id) and not
      ((public.photo_sharing_status(target_family_id)->>'familyAuthorized')::boolean) then
      raise exception 'A parent must authorize photo sharing first' using errcode = '42501';
    end if;
    insert into photo_sharing_consents(family_id, user_id) values(target_family_id, auth.uid())
    on conflict(family_id,user_id) do update set accepted_at = now();
  elsif public.is_family_parent(target_family_id) then
    -- A parent's withdrawal stops uploads for the whole family until authorized again.
    delete from photo_sharing_consents where family_id = target_family_id;
  else
    delete from photo_sharing_consents where family_id = target_family_id and user_id = auth.uid();
  end if;
end;
$$;
create function public.can_share_chore_photo(target_family_id uuid)
returns boolean language sql security definer set search_path = public as $$
  select public.is_family_member(target_family_id)
    and not exists(select 1 from account_deletion_requests where user_id = auth.uid())
    and exists(select 1 from photo_sharing_consents where family_id = target_family_id and user_id = auth.uid())
    and (public.photo_sharing_status(target_family_id)->>'familyAuthorized')::boolean;
$$;
revoke all on function public.photo_sharing_status(uuid), public.set_photo_sharing_consent(uuid,boolean), public.can_share_chore_photo(uuid) from public, anon;
grant execute on function public.photo_sharing_status(uuid), public.set_photo_sharing_consent(uuid,boolean), public.can_share_chore_photo(uuid) to authenticated;

create function public.can_upload_chore_photo(object_path text)
returns boolean language sql security definer set search_path = public as $$
  select exists(select 1 from task_occurrences t join weeks w on w.id = t.week_id
    join child_profiles c on c.id = t.child_id
    where w.family_id::text = split_part(object_path,'/',1)
      and t.id::text = split_part(object_path,'/',2)
      and c.linked_user_id = auth.uid() and public.can_share_chore_photo(w.family_id)
      and coalesce((select photo_evidence_enabled from family_evidence_policies where family_id = w.family_id), true)
      and not exists(select 1 from evidence_removal_queue where path = object_path));
$$;
revoke all on function public.can_upload_chore_photo(text) from public, anon;
grant execute on function public.can_upload_chore_photo(text) to authenticated;
-- Restrictive policies also cover pre-existing permissive parent upload policies.
create policy photo_consent_insert on storage.objects as restrictive for insert to authenticated
with check (bucket_id <> 'chore-evidence' or public.can_upload_chore_photo(name));
create policy photo_consent_update on storage.objects as restrictive for update to authenticated
using (bucket_id <> 'chore-evidence') with check (bucket_id <> 'chore-evidence');

create function public.guard_photo_registration() returns trigger
language plpgsql security definer set search_path = public as $$
declare fid uuid;
begin
  if NEW.image_path is null then return NEW; end if;
  if TG_OP = 'UPDATE' and NEW.image_path is not distinct from OLD.image_path then return NEW; end if;
  perform pg_advisory_xact_lock(hashtextextended(NEW.image_path, 0));
  select w.family_id into fid from task_occurrences t join weeks w on w.id = t.week_id
    where t.id = NEW.task_occurrence_id;
  if not public.can_share_chore_photo(fid) then
    raise exception 'Photo sharing consent required' using errcode = '42501';
  end if;
  if exists(select 1 from evidence_removal_queue where path = NEW.image_path) or not exists (
    select 1 from storage.objects where bucket_id = 'chore-evidence' and name = NEW.image_path) then
    raise exception 'Photo expired or missing. Take another photo.' using errcode = '22023';
  end if;
  if not public.can_upload_chore_photo(NEW.image_path) or split_part(NEW.image_path,'/',2) <> NEW.task_occurrence_id::text then
    raise exception 'Photo does not belong to this chore' using errcode = '42501';
  end if;
  return NEW;
end;
$$;
create trigger guard_photo_registration before insert or update of image_path on public.chore_submissions
for each row execute function public.guard_photo_registration();

create function public.queue_orphaned_evidence(batch_size integer default 100) returns integer
language plpgsql security definer set search_path = public as $$
declare candidate record; queued integer := 0;
begin
  for candidate in select o.name from storage.objects o
    where o.bucket_id = 'chore-evidence' and greatest(o.created_at,o.updated_at) < now() - interval '24 hours'
      and not exists(select 1 from chore_submissions s where s.image_path = o.name or s.thumbnail_path = o.name)
      and not exists(select 1 from evidence_removal_queue q where q.path = o.name)
    order by o.created_at limit least(greatest(batch_size,1),100)
  loop
    perform pg_advisory_xact_lock(hashtextextended(candidate.name,0));
    if not exists(select 1 from chore_submissions where image_path = candidate.name or thumbnail_path = candidate.name) then
      insert into evidence_removal_queue(path) values(candidate.name) on conflict do nothing;
      queued := queued + 1;
    end if;
  end loop;
  return queued;
end;
$$;
revoke all on function public.queue_orphaned_evidence(integer) from public, anon, authenticated;
grant execute on function public.queue_orphaned_evidence(integer) to service_role;

-- A deletion request cannot rejoin a household while background cleanup is pending.
create function public.guard_deleting_membership() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists(select 1 from account_deletion_requests where user_id = NEW.user_id) then
    raise exception 'Account deletion is in progress' using errcode = '42501';
  end if;
  return NEW;
end;
$$;
create trigger guard_deleting_membership before insert or update on public.family_members
for each row execute function public.guard_deleting_membership();

-- Keep shared financial facts, but remove attribution to a deleted parent.
alter table public.allowance_settlements alter column confirmed_by drop not null;
alter table public.allowance_settlements drop constraint allowance_settlements_check;
alter table public.allowance_settlements add check (paid_at is not null or paid_by is null);

create function public.prepare_account_deletion(target_user_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare doomed_families uuid[]; doomed_children uuid[]; fid uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended(target_user_id::text, 1));
  if exists(select 1 from account_deletion_requests where user_id = target_user_id) then return; end if;
  if not exists(select 1 from auth.users where id = target_user_id) then
    raise exception 'Account not found';
  end if;
  -- Serialize parent deletions so two simultaneous departures cannot orphan a family.
  for fid in select family_id from family_members where user_id = target_user_id order by family_id loop
    perform 1 from families where id = fid for update;
  end loop;
  select coalesce(array_agg(m.family_id), '{}') into doomed_families from family_members m
    where m.user_id = target_user_id and m.role = 'parent' and not exists (
      select 1 from family_members other where other.family_id = m.family_id
        and other.role = 'parent' and other.user_id <> target_user_id);
  select coalesce(array_agg(id), '{}') into doomed_children from child_profiles
    where linked_user_id = target_user_id or family_id = any(doomed_families);
  insert into account_deletion_requests(user_id) values(target_user_id);

  insert into evidence_removal_queue(path, deletion_user_id)
    select o.name, target_user_id from storage.objects o where o.bucket_id = 'chore-evidence' and (
      o.owner_id = target_user_id::text or split_part(o.name,'/',1) = any(doomed_families::text[]) or exists(
        select 1 from chore_submissions s where s.child_id = any(doomed_children)
          and (s.image_path = o.name or s.thumbnail_path = o.name)))
    on conflict(path) do update set deletion_user_id = excluded.deletion_user_id;

  -- Remove closed-period locks only for records being erased.
  delete from allowance_settlements where week_id in (select id from weeks where child_id = any(doomed_children));
  delete from ledger_entries where child_id = any(doomed_children);
  delete from child_profiles where id = any(doomed_children);
  delete from families where id = any(doomed_families);

  update allowance_settlements set confirmed_by = null where confirmed_by = target_user_id;
  update allowance_settlements set paid_by = null where paid_by = target_user_id;
  -- The settled-period guard permits attribution-only changes during this service operation.
  update ledger_entries set created_by = null where created_by = target_user_id;
  update task_occurrences set excused_by_parent_id = null where excused_by_parent_id = target_user_id;
  update chore_submissions set parent_decision = parent_decision - 'parent_id'
    where parent_decision->>'parent_id' = target_user_id::text;
  delete from child_invites where created_by_parent_id = target_user_id or accepted_child_user_id = target_user_id;
  delete from parent_invites where created_by_parent_id = target_user_id or accepted_parent_user_id = target_user_id;
  update child_profiles set created_by_parent_id = null where created_by_parent_id = target_user_id;
  delete from task_nudges where created_by = target_user_id;
  delete from photo_sharing_consents where user_id = target_user_id;
  delete from apns_device_tokens where user_id = target_user_id;
  delete from family_members where user_id = target_user_id;
end;
$$;
revoke all on function public.prepare_account_deletion(uuid) from public, anon, authenticated;
grant execute on function public.prepare_account_deletion(uuid) to service_role;

create or replace function public.guard_settled_period_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare target_week uuid;
begin
  if TG_OP = 'UPDATE' and auth.role() = 'service_role' then
    if TG_TABLE_NAME = 'ledger_entries' then
      if NEW.created_by is null
        and exists(select 1 from account_deletion_requests where user_id = OLD.created_by)
        and (to_jsonb(NEW) - 'created_by') = (to_jsonb(OLD) - 'created_by') then return NEW; end if;
    elsif TG_TABLE_NAME = 'task_occurrences' then
      if NEW.excused_by_parent_id is null
        and exists(select 1 from account_deletion_requests where user_id = OLD.excused_by_parent_id)
        and (to_jsonb(NEW) - array['excused_by_parent_id','updated_at']) =
            (to_jsonb(OLD) - array['excused_by_parent_id','updated_at']) then return NEW; end if;
    end if;
  end if;
  target_week := case when TG_OP = 'DELETE' then OLD.week_id else NEW.week_id end;
  perform 1 from weeks where id = target_week for update;
  if exists(select 1 from allowance_settlements where week_id = target_week) then
    raise exception 'This allowance period is confirmed and cannot be changed.' using errcode = '22023';
  end if;
  if TG_OP = 'UPDATE' and OLD.week_id is distinct from NEW.week_id then
    raise exception 'Moving entries between allowance periods is not supported.' using errcode = '22023';
  end if;
  if TG_OP = 'DELETE' then return OLD; end if;
  return NEW;
end;
$$;
notify pgrst, 'reload schema';
