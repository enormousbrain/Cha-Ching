alter table public.child_invites
  alter column token_hash drop not null;

alter table public.parent_invites
  alter column token_hash drop not null;

comment on column public.child_invites.token_hash is
  'SHA-256 invite token hash. Cleared after the invite expires.';

comment on column public.parent_invites.token_hash is
  'SHA-256 invite token hash. Cleared after the invite expires.';
