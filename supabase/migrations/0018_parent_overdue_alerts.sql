alter table public.chore_definitions
  add column if not exists parent_alert_enabled boolean not null default false,
  add column if not exists parent_alert_delay_minutes integer not null default 0;

alter table public.chore_definitions
  drop constraint if exists chore_definitions_parent_alert_delay_check;
alter table public.chore_definitions
  add constraint chore_definitions_parent_alert_delay_check
  check (parent_alert_delay_minutes between 0 and 1440);

create table if not exists public.apns_device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  family_id uuid not null references public.families(id) on delete cascade,
  token text not null,
  environment text not null default 'production' check (environment in ('sandbox', 'production')),
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique(user_id, token)
);
alter table public.apns_device_tokens enable row level security;
drop policy if exists "users manage own APNs tokens" on public.apns_device_tokens;
create policy "users manage own APNs tokens" on public.apns_device_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid() and public.is_family_member(family_id));

create table if not exists public.parent_overdue_alerts (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null references public.child_profiles(id) on delete cascade,
  chore_definition_id uuid not null references public.chore_definitions(id) on delete cascade,
  task_occurrence_id uuid not null references public.task_occurrences(id) on delete cascade,
  message text not null,
  status text not null default 'pending' check (status in ('pending', 'sent', 'dismissed')),
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique(task_occurrence_id)
);
alter table public.parent_overdue_alerts enable row level security;
drop policy if exists "family members read overdue alerts" on public.parent_overdue_alerts;
create policy "family members read overdue alerts" on public.parent_overdue_alerts
  for select using (public.is_family_member(family_id));

create or replace function public.queue_parent_overdue_alerts(maintenance_at timestamptz default now())
returns integer language plpgsql security definer set search_path = public as $$
declare queued integer;
begin
  insert into public.parent_overdue_alerts (family_id, child_id, chore_definition_id, task_occurrence_id, message)
  select chore.family_id, occurrence.child_id, chore.id, occurrence.id,
    chore.title || ' is still unfinished.'
  from public.task_occurrences occurrence
  join public.chore_definitions chore on chore.id = occurrence.chore_definition_id
  where chore.parent_alert_enabled
    and chore.is_paused = false and chore.archived_at is null
    and occurrence.status in ('upcoming', 'due')
    and occurrence.due_at + make_interval(mins => chore.parent_alert_delay_minutes) <= maintenance_at
  on conflict (task_occurrence_id) do nothing;
  get diagnostics queued = row_count;
  return queued;
end;
$$;
revoke all on function public.queue_parent_overdue_alerts(timestamptz) from public, anon, authenticated;
grant execute on function public.queue_parent_overdue_alerts(timestamptz) to service_role;
