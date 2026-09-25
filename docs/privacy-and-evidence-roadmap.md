# Privacy and Evidence Roadmap

This is the product direction and implementation tracker for chore evidence, image retention, and device sync.

## Product Principles

- Photo evidence should be optional at the family level and configurable per chore.
- Parents should be able to choose whether a chore requires a photo, allows an optional photo, needs parent-only review, or needs no verification.
- Photos are temporary evidence, not family history. Keep task status, decisions, and allowance ledger history; delete images aggressively.
- Block uploads that appear to contain a person or face before the image leaves the device.
- Deleting evidence should be automatic, with a short configurable undo/grace window for accidental parent actions.

## MVP Defaults

- Family photo evidence: enabled, but configurable.
- Per-chore verification: use the existing `verification_mode` values:
  - `photo_required`
  - `photo_optional`
  - `parent_only`
  - `no_verification`
- People-in-photo blocking: on by default.
- Evidence deletion: delete after parent review plus a 10-minute undo grace window.
- Period backstop: delete any remaining evidence the day after the allowance period closes and disputes are settled.
- Keep after deletion: task title, submission time, AI result metadata, parent decision, reviewer, allowance impact, `evidence_deleted_at`, and deletion reason.
- Do not keep thumbnails after deletion; thumbnails are still photo evidence.

## Proposed Data Model

Add a family policy table:

```sql
create table public.family_evidence_policies (
  family_id uuid primary key references public.families(id) on delete cascade,
  photo_evidence_enabled boolean not null default true,
  default_verification_mode text not null default 'photo_optional',
  block_people_in_photos boolean not null default true,
  evidence_retention_mode text not null default 'after_parent_review',
  delete_grace_minutes integer not null default 10,
  delete_after_period_close_days integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (default_verification_mode in ('photo_required', 'photo_optional', 'parent_only', 'no_verification')),
  check (evidence_retention_mode in ('after_parent_review', 'after_period_close', 'manual_only'))
);
```

Extend chore definitions:

```sql
alter table public.chore_definitions
  add column if not exists block_people_in_photos boolean,
  add column if not exists evidence_retention_mode text,
  add column if not exists evidence_delete_grace_minutes integer;
```

Extend submissions:

```sql
alter table public.chore_submissions
  alter column image_path drop not null,
  add column if not exists evidence_status text not null default 'available',
  add column if not exists evidence_delete_after timestamptz,
  add column if not exists evidence_deleted_at timestamptz,
  add column if not exists evidence_delete_reason text,
  add column if not exists people_block_result jsonb,
  add constraint chore_submissions_evidence_status_check
    check (evidence_status in ('available', 'pending_delete', 'deleted', 'blocked_before_upload'));
```

## Capture Flow

1. Child opens a task.
2. App checks the chore's verification mode.
3. If photos are disabled or the chore is `no_verification`, the child can submit without a photo.
4. If a photo is captured, the app runs on-device person/face detection.
5. If a person or face is detected, the image is discarded locally and never uploaded.
6. If the image passes the local check, upload to Supabase Storage and create a submission row.
7. AI review can run only when a photo exists.
8. Parent reviews the task.
9. Parent decision writes to Supabase and schedules evidence deletion according to the effective family/chore policy.
10. A delete job removes the image from Storage, clears image paths, and leaves audit metadata.

## Deletion Flow

Evidence deletion should happen through a Supabase Edge Function using the Storage API, not raw SQL deletes against storage tables.

Planned functions:

- `decide-submission`: parent approval/rejection/excuse/retake; updates occurrence, ledger, submission decision, and evidence deletion schedule.
- `delete-submission-evidence`: deletes Storage objects, clears `image_path` / `thumbnail_path`, sets `evidence_status = 'deleted'`, and records `evidence_deleted_at`.
- `retention-cleanup`: nightly backstop that deletes any evidence past `evidence_delete_after`, plus expired invite tokens.

Parents may undo an accidental decision during the grace window by updating the decision before evidence deletion executes. If evidence has already been deleted, the app keeps the decision and task history but cannot restore the original image.

## Device Sync

Remote review sync should work like this:

1. Parent reviews a submitted task from their phone.
2. App calls `decide-submission`.
3. Supabase updates the occurrence, submission, ledger, and evidence deletion schedule in one server-side operation.
4. Child app refreshes remote state by manual refresh, lightweight polling, realtime subscription, or push-triggered fetch.
5. Child app writes the refreshed state into the shared App Group snapshot.
6. Home Screen and Lock Screen widgets update from the local shared snapshot.

Widgets should not talk directly to Supabase. The main app remains the sync bridge between Supabase and WidgetKit shared state.

## Implementation Order

Done:

- Remote parent review writes: approve, reject, excuse, retake, and related ledger updates.
- Remote refresh on app foreground plus a manual refresh affordance for parent and child.
- Best-effort iOS background app refresh that republishes the local widget snapshot after remote sync.
- Family/chore evidence settings UI and schema.
- Child no-photo submission flow for chores that allow it.
- Evidence deletion scheduling in parent review actions, including chore overrides and the undo grace window.
- Parent-authorized evidence deletion plus a secret-protected cleanup worker that removes due Storage objects, preserves audit metadata, and clears expired invite token hashes.
- A Supabase cron schedule that invokes retention cleanup every 15 minutes.
- Transactional photo registration that verifies the authenticated linked child and records the submission before AI review begins.
- Production-safe AI failure behavior: submitted photos remain pending for a parent and never fall back to convincing mock results.
- Authenticated parent evidence thumbnails and full-screen private photo viewing.
- Verdict-aware AI presentation that does not equate confidence with task completion or parent approval.
- Parent authorization and uploader consent enforced by Storage policies and registration triggers; withdrawal blocks new uploads.
- In-app privacy/account settings, account deletion, and durable Storage/Auth cleanup retries. See [implementation notes](privacy-account-settings.md).
- Scheduled cleanup for abandoned uploads older than 24 hours, excluding registered evidence and pending reviews.

Next:

1. Physical-device smoke test for on-device person/face blocking before upload.
2. Realtime or push-triggered refresh for faster cross-device updates.
3. Publish the privacy/support pages, configure the Apple sign-in revocation key, and verify consent/deletion on disposable physical-device accounts.
