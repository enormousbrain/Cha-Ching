-- Stars recognize initiative, not app usage. Only parents award or approve spending.
create table public.initiative_stars (
  id uuid primary key,
  child_id uuid not null references public.child_profiles(id) on delete cascade,
  amount integer not null check (amount in (1,-5)),
  reason text not null check (length(trim(reason)) between 1 and 240),
  occurrence_id uuid references public.task_occurrences(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index initiative_stars_one_award_per_chore on public.initiative_stars(occurrence_id)
  where amount=1 and occurrence_id is not null;
create index initiative_stars_child on public.initiative_stars(child_id,created_at);

create table public.star_credit_requests (
  id uuid primary key,
  child_id uuid not null references public.child_profiles(id) on delete cascade,
  occurrence_id uuid not null references public.task_occurrences(id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','approved','declined')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create unique index star_credit_one_request_per_chore on public.star_credit_requests(occurrence_id);

alter table public.initiative_stars enable row level security;
alter table public.star_credit_requests enable row level security;
create policy "own child or parent can read stars" on public.initiative_stars for select to authenticated
  using (public.is_linked_child_profile(child_id) or exists(select 1 from public.child_profiles c where c.id=child_id and public.is_family_parent(c.family_id)));
create policy "own child or parent can read credit requests" on public.star_credit_requests for select to authenticated
  using (public.is_linked_child_profile(child_id) or exists(select 1 from public.child_profiles c where c.id=child_id and public.is_family_parent(c.family_id)));
revoke all on public.initiative_stars,public.star_credit_requests from anon,authenticated;
grant select on public.initiative_stars,public.star_credit_requests to authenticated;

create function public.award_initiative_star(target_id uuid, target_child_id uuid, target_reason text, target_occurrence_id uuid default null)
returns void language plpgsql security definer set search_path=public as $$
declare child public.child_profiles%rowtype; existing public.initiative_stars%rowtype;
begin
  select * into child from public.child_profiles where id=target_child_id for update;
  if child.id is null or not public.is_family_parent(child.family_id) then raise exception 'Only a family parent can award a star.'; end if;
  if target_reason is null or length(trim(target_reason)) not between 1 and 240 then raise exception 'Describe the initiative in 1 to 240 characters.'; end if;
  select * into existing from public.initiative_stars where id=target_id;
  if found then
    if existing.child_id=target_child_id and existing.amount=1 and existing.reason=trim(target_reason)
       and existing.occurrence_id is not distinct from target_occurrence_id then return; end if;
    raise exception 'This award has already been used.';
  end if;
  if target_occurrence_id is not null and not exists(select 1 from public.task_occurrences
      where id=target_occurrence_id and child_id=target_child_id and status='approved') then
    raise exception 'Review and approve this chore before recognizing initiative.';
  end if;
  if target_occurrence_id is not null and exists(select 1 from public.initiative_stars where occurrence_id=target_occurrence_id and amount=1) then
    raise exception 'This chore already earned a star.';
  end if;
  insert into public.initiative_stars(id,child_id,amount,reason,occurrence_id,created_by)
    values(target_id,target_child_id,1,trim(target_reason),target_occurrence_id,auth.uid());
end $$;

create function public.request_star_credit(target_id uuid, target_occurrence_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare task public.task_occurrences%rowtype; child public.child_profiles%rowtype; existing public.star_credit_requests%rowtype;
begin
  select * into task from public.task_occurrences where id=target_occurrence_id;
  select * into child from public.child_profiles where id=task.child_id for update;
  if child.id is null or not (public.is_linked_child_profile(child.id) or public.is_family_parent(child.family_id)) then
    raise exception 'This chore is not available to your account.';
  end if;
  select * into existing from public.star_credit_requests where id=target_id or occurrence_id=target_occurrence_id;
  if found then
    if existing.child_id=child.id and existing.occurrence_id=target_occurrence_id then return; end if;
    raise exception 'This request has already been used.';
  end if;
  if task.status not in ('missed','rejected') or exists(select 1 from public.allowance_settlements where week_id=task.week_id)
     or not exists(select 1 from public.ledger_entries where related_occurrence_id=task.id and entry_type='deduction' and not is_voided and amount_cents>0) then
    raise exception 'Choose a missed deduction in an unconfirmed allowance period.';
  end if;
  if (select coalesce(sum(amount),0) from public.initiative_stars where child_id=child.id)<5 then raise exception 'Five stars are needed for a credit.'; end if;
  insert into public.star_credit_requests(id,child_id,occurrence_id) values(target_id,child.id,task.id);
end $$;

create function public.decide_star_credit(target_id uuid, approve boolean)
returns void language plpgsql security definer set search_path=public as $$
declare request public.star_credit_requests%rowtype; child public.child_profiles%rowtype; task public.task_occurrences%rowtype;
begin
  select * into request from public.star_credit_requests where id=target_id;
  select * into child from public.child_profiles where id=request.child_id for update;
  if child.id is null or not public.is_family_parent(child.family_id) then raise exception 'Only a family parent can decide a credit.'; end if;
  select * into request from public.star_credit_requests where id=target_id for update;
  if request.status<>'pending' then return; end if;
  if approve is null then raise exception 'Choose approve or decline.'; end if;
  if approve then
    select * into task from public.task_occurrences where id=request.occurrence_id;
    -- Use the same week-before-occurrence lock order as allowance confirmation/review.
    perform 1 from public.weeks where id=task.week_id for update;
    select * into task from public.task_occurrences where id=request.occurrence_id for update;
    if task.status not in ('missed','rejected') or exists(select 1 from public.allowance_settlements where week_id=task.week_id) then
      raise exception 'This chore changed or its allowance period is confirmed. Decline this request.';
    end if;
    if (select coalesce(sum(amount),0) from public.initiative_stars where child_id=child.id)<5 then raise exception 'Not enough stars remain.'; end if;
    update public.ledger_entries set is_voided=true where related_occurrence_id=task.id and entry_type='deduction' and not is_voided and amount_cents>0;
    if not found then raise exception 'This deduction was already cleared. Decline this request.'; end if;
    insert into public.initiative_stars(id,child_id,amount,reason,occurrence_id,created_by)
      values(request.id,child.id,-5,'Missed-chore credit',task.id,auth.uid());
    -- Leave missed/rejected status untouched: a credit is not proof of completion.
  end if;
  update public.star_credit_requests set status=case when approve then 'approved' else 'declined' end,decided_at=now() where id=target_id;
end $$;

revoke all on function public.award_initiative_star(uuid,uuid,text,uuid),public.request_star_credit(uuid,uuid),public.decide_star_credit(uuid,boolean) from public,anon;
grant execute on function public.award_initiative_star(uuid,uuid,text,uuid),public.request_star_credit(uuid,uuid),public.decide_star_credit(uuid,boolean) to authenticated;
create function public.initiative_star_balance(target_child_id uuid) returns bigint
language plpgsql stable security definer set search_path=public as $$
begin
  if not exists(select 1 from public.child_profiles where id=target_child_id and
    (public.is_linked_child_profile(id) or public.is_family_parent(family_id))) then
    raise exception 'This child is not available to your account.';
  end if;
  return (select coalesce(sum(amount),0) from public.initiative_stars where child_id=target_child_id);
end $$;
revoke all on function public.initiative_star_balance(uuid) from public,anon;
grant execute on function public.initiative_star_balance(uuid) to authenticated;
notify pgrst,'reload schema';
