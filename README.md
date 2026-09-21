# Family Chore Allowance Prototype

Phase 1 local prototype for the PRD in `/Users/jessebarrueta/Downloads/do-good-chore-allowance-prd.md`.

## App Name

The user-facing app name is intentionally centralized:

```text
Configuration/AppBrand.xcconfig
```

Change `APP_DISPLAY_NAME` there when the final name is decided. The SwiftUI app reads `CFBundleDisplayName` from the bundle, so UI copy should not hard-code the product name.

Current display name: `ChaChing`

## What Is Built

- SwiftUI iPhone app project: `ChaChing.xcodeproj`
- Foundation-only core package for deterministic allowance logic
- Supabase Swift package linked through the Xcode project
- Supabase client configuration using the publishable project key
- Initial Supabase SQL migrations for families, child profiles, child/parent invites, remote family bootstrapping, chores, occurrences, submissions, ledger entries, RLS, and private evidence storage
- Seed family state for Daddy/Zoe with `$15.00` base allowance and `$13.50` current total
- Role-aware parent and child app shells
- Ledger-driven allowance summary
- Idempotent missed-task deductions
- Excuse flow that voids deductions
- Parent bonus flow
- Parent child-profile and invite-link flow with iOS share sheet handoff
- Supabase invite creation writes for child and parent links, with local preview behavior before sign-in
- Invite acceptance service that requests/verifies SMS OTP and calls the `accept-child-invite` Edge Function
- Supabase Edge Function source for hashing invite tokens and linking authenticated child users
- Parent invite flow for a second parent account, with `Daddy` / `Mamma` seed display names
- Supabase schema and Edge Function source for `parent_invites`
- Child dashboard
- Task detail
- Native camera JPEG evidence capture with a debug-only simulator mock
- Transactional Supabase evidence registration plus advisory `review-evidence` AI review; production upload failures never become mock successes
- Authenticated parent evidence thumbnails and full-screen private photo review
- Verdict-aware AI copy that keeps completion, confidence, and parent approval as separate concepts
- Parent Family Sync card for email or phone OTP sign-in, remote family bootstrap, Supabase-backed family loading, and sign-out
- Supabase-backed role routing from `family_members.role`
- Supabase parent review decision RPC and app wiring for approve, reject, excuse, and retake actions
- Remote family refresh on app foreground, toolbar refresh, and pull-to-refresh for parent/child state
- Best-effort iOS background app refresh that pulls Supabase state, republishes the App Group widget snapshot, and refreshes local notification schedules
- Supabase write-back for parent-created bonuses, chore title/deduction/time edits, and allowance amount/schedule changes
- Remote-first authenticated mutations that update local app and widget state only after Supabase succeeds, with stable retry IDs and retained form input after failures
- Linked-child Supabase RPC for requesting a parent excuse review without granting broader occurrence update access
- Parent review queue actions
- Focused parent review inbox with Needs review, Today, and History sections; task decisions use a persistent iPhone Calendar-style response bar
- Ledger-based allowance trajectory in Review and Earnings, with compact Home Screen widget sparklines shared by parents and children
- Parent chore editing
- Supabase-backed current earnings, daily ledger activity, and archived allowance-period browsing
- Static lock-screen and home-screen widget previews
- Addable WidgetKit extension with Home Screen and Lock Screen allowance widgets backed by shared App Group state
- Parent allowance controls for the next period's amount and weekly or every-two-week cadence
- Parent evidence privacy controls for family photo evidence, default verification mode, people blocking, retention mode, and cleanup windows
- On-device Vision face and body checks that prevent protected evidence photos from uploading when a person may be visible
- Per-chore proof settings for photo required, photo optional, parent review, or no proof
- Child no-photo submission flow for chores that allow it
- Local notification permission flow and scheduling for chore due times plus allowance day
- Child allowance-day message handoff using Messages or share-sheet fallback
- Rollover debt calculation when deductions exceed the current allowance period

## Privacy and Evidence Direction

Chore evidence is privacy-first and parent-configurable:

- Photo evidence can be disabled for a family and configured per chore.
- Chores can be `photo_required`, `photo_optional`, `parent_only`, or `no_verification`.
- People/face blocking should run on-device before upload; blocked images never leave the phone.
- Evidence photos should be temporary. MVP default: delete after parent review plus a short undo grace window, with a post-allowance-period cleanup backstop.
- Keep task decisions, allowance history, and lightweight AI/review metadata; do not keep original images or thumbnails after evidence deletion.

See:

```text
docs/privacy-and-evidence-roadmap.md
```

## Widget State

The main app writes the current allowance and next-chore summary to the shared App Group:

```text
group.com.artofsullivan.chaching
```

The widget reads that shared snapshot and falls back to sample data if the group is unavailable. For TestFlight/device archives, make sure App Groups is enabled for both `com.artofsullivan.chaching` and `com.artofsullivan.chaching.widgets` in the Apple team.

The main app also registers an iOS `BGAppRefreshTask` for `com.artofsullivan.chaching.refresh`. When iOS grants background time, the app refreshes remote family state, writes a new shared snapshot, asks WidgetKit to reload, and refreshes local notifications. This is best-effort background refresh, not a guaranteed polling interval.

## Verified

```sh
swift test
xcodebuild -project ChaChing.xcodeproj -scheme ChaChing \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

The current core suite contains 32 passing tests, and the app plus widget extension compile for the iOS Simulator.

### Snooze and Arrival Reminders

The child's Today bell opens Reminders settings. Enable notifications there; expand a chore notification to choose Snooze 15 min or Snooze 1 hour. Alerts sharing a minute are combined. Snoozes persist on the phone across app launches and syncs, and do not alter deadlines, grace windows, or allowance deductions. Reminders stop when the app learns that an occurrence is submitted, completed, excused, or otherwise closed; future occurrences still receive reminders.

Scheduling uses a rolling 14-day window with up to 56 timed alerts, replenished during foreground and best-effort background refresh. A phone that does not refresh can eventually exhaust that window or show an alert based on older cached state. This is not server push delivery.

While physically at home, use **Use Current Location as Home** to enable the optional **When I get home** notification action. The coordinate and deferred reminders stay in local app storage and are not sent to Supabase. iOS handles a one-time arrival trigger with a 200-meter region and When In Use permission; delivery can be delayed. Disabling arrival reminders restores future timed reminders. Arrival reminders do not excuse lateness, and stale arrivals are reconciled on the next refresh.

Physical-device QA after the next TestFlight upload:
1. Enable notifications on Zoe's phone; expand an upcoming alert and snooze it. Confirm only one reminder appears at the new time.
2. Submit the chore before the snooze fires, then confirm its remaining alerts are canceled after sync.
3. Schedule two chores for the same minute and confirm one grouped alert opens the matching chores.
4. Save home while there, leave the region, defer an alert with **When I get home**, and return. Confirm the arrival alert opens the chore list and does not reappear after dismissal and refresh.
5. Verify light/dark appearance, notification permissions, and Focus settings on the actual phone. Simulator and planner tests do not prove real-world geofence delivery.

The allowance graph starts with the period's base ledger amount and applies active bonuses, deductions, and adjustments in timestamp order. Voided entries are excluded, so it represents the currently effective ledger rather than a historical audit of subsequently reversed decisions. The line ends at the latest refresh within the period; future days are left blank. Negative balances show rollover debt, while the payable balance remains floored at zero. Older widget snapshots without graph points continue to use the progress bar until the app refreshes them.

## Supabase

Client config lives in:

```text
App/Networking/SupabaseClientProvider.swift
```

The checked-in key is the Supabase publishable key, which is expected to be present in client apps. Do not commit the database password, service-role key, or OpenAI keys.

### Auth

Family Sync supports email OTP and phone OTP. The production Supabase project uses Twilio Verify for phone OTP. For a new Supabase environment, configure a Twilio Verify service under Authentication > Sign In / Providers > Phone before testing SMS codes.

For email OTP, update Supabase Auth templates so the email shows the one-time code. Add `{{ .Token }}` to both the Confirm Signup and Magic Link templates. Keep `{{ .ConfirmationURL }}` as a backup link if desired, but set the Auth Site URL away from localhost, for example `https://enormousbrain.com/cha-ching/`, and add any app/web callback URLs to the allowed redirect URLs list.

### Edge Function Secrets

Use Supabase secrets for server-side API keys and model configuration. The checked-in template is:

```text
supabase-secrets.example.env
```

Create your local secrets file, fill in the OpenAI key, then upload it to Supabase:

```sh
cp supabase-secrets.example.env .env.supabase.local
$EDITOR .env.supabase.local
scripts/set-supabase-secrets.sh
```

If the CLI has not been authenticated yet, run `supabase login` first, or set `SUPABASE_ACCESS_TOKEN` for the command.

The script targets project ref `pjvgtmxyxrfhabyuefne` by default. To override it:

```sh
SUPABASE_PROJECT_REF=your-project-ref scripts/set-supabase-secrets.sh
```

Current app secrets:

```text
OPENAI_API_KEY
OPENAI_REVIEW_MODEL
OPENAI_REVIEW_IMAGE_DETAIL
OPENAI_REVIEW_PROMPT_VERSION
```

Supabase-hosted Edge Functions are expected to provide `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to the invite/review functions. Do not put those values in the iOS app.

The schema lives in:

```text
supabase/migrations/0001_initial_schema.sql
supabase/migrations/0002_child_profiles_and_invites.sql
supabase/migrations/0003_parent_invites.sql
supabase/migrations/0004_family_bootstrap.sql
supabase/migrations/0005_parent_review_decisions.sql
supabase/migrations/0006_parent_settings_sync.sql
supabase/migrations/0007_evidence_policy_settings.sql
supabase/migrations/0008_task_nudges.sql
supabase/migrations/0009_chore_recurrence.sql
supabase/migrations/0010_task_deadlines.sql
supabase/migrations/0011_chore_lifecycle.sql
supabase/migrations/0012_evidence_deletion_schedule.sql
supabase/migrations/0013_retention_cleanup.sql
supabase/migrations/0014_submission_registration.sql
supabase/migrations/0015_automatic_family_maintenance.sql
supabase/migrations/0016_child_excuse_requests.sql
```

`0004_family_bootstrap.sql` adds the `bootstrap_preview_family` RPC used by the parent Family Sync card. A signed-in parent can create the initial remote family, child profile, current week, starting allowance ledger entry, and preview chore schedule from the app.

`0005_parent_review_decisions.sql` adds the `decide_chore_submission` RPC used by parent review actions. It updates the occurrence, parent decision metadata, and any related deduction ledger row in one server-side transaction.

`0006_parent_settings_sync.sql` adds family allowance cadence, allowance weekday, and next allowance date columns so parent schedule changes can sync across devices.

`0007_evidence_policy_settings.sql` adds `family_evidence_policies`, per-chore evidence override columns, nullable submission images, and the `submit_chore_without_photo` RPC used by child no-photo submissions.

`0008_task_nudges.sql` adds parent-created task nudges that child devices can surface as notifications after a remote refresh.

`0009_chore_recurrence.sql` adds the idempotent `ensure_current_task_occurrences` RPC. It creates matching daily, weekly, or one-time chores for the family’s local day, opens the next allowance period when needed, and carries excess deductions into the next starting balance.

`0010_task_deadlines.sql` adds the transactional `process_task_occurrence_deadlines` RPC. It advances upcoming chores to due, closes expired chores as missed, and creates each automatic deduction exactly once. Expired preview chores from before the feature was enabled are grandfathered as excused.

`0011_chore_lifecycle.sql` adds archived chore state and the parent-only `set_chore_lifecycle` RPC. Pausing or archiving a chore excuses its open occurrences, stops future scheduling, and preserves completed task and allowance history.

`0012_evidence_deletion_schedule.sql` adds evidence lifecycle metadata and updates parent review decisions to schedule photo deletion using the effective family/chore retention policy and undo grace window.

`0013_retention_cleanup.sql` allows expired invite token hashes to be cleared after the invite is no longer usable.

`0014_submission_registration.sql` adds an authenticated, transactional photo-submission RPC and hardens no-photo submissions so only the linked child account with a child family role can submit assigned chores.

`0015_automatic_family_maintenance.sql` moves allowance-period and task-deadline maintenance into idempotent server functions and installs a Supabase `pg_cron` job that runs every 15 minutes. After a parent saves the allowance amount, cadence, and next allowance date, periods close and reopen automatically, rollover debt is applied, missed deductions are created, and the current day's recurring chores are generated even when no phone opens the app. App refresh continues to call the same maintenance RPCs as an immediate fallback.

`0016_child_excuse_requests.sql` adds the authenticated `request_chore_excuse` RPC. Only the account linked to the occurrence's child profile can request parent review, and the child receives no general occurrence-update permission.

### Mutation Behavior

Authenticated writes are remote-first. The app changes its local model, widget snapshot, and success state only after Supabase confirms the write. If a write fails, the current server-backed state and the user's draft input remain intact so the same action can be retried safely. New records use stable IDs during retries to prevent duplicate invites, chores, occurrences, and bonus entries.

When no Supabase session exists, the bundled seed family remains an explicit local preview. Preview mutations are intentionally local-only and are replaced when a signed-in family is loaded.

Evidence files should be stored under paths beginning with the family id:

```text
{familyId}/{taskOccurrenceId}/{submissionId}.jpg
```

Invite acceptance is handled by:

```text
supabase/functions/accept-child-invite/index.ts
```

The function expects an authenticated Supabase user and a raw invite token. It hashes the token with SHA-256, matches it against `child_invites.token_hash`, links the child profile to the authenticated user, upserts the `family_members` child row, and marks the invite accepted.

Second-parent acceptance is handled by:

```text
supabase/functions/accept-parent-invite/index.ts
supabase/migrations/0003_parent_invites.sql
```

The parent function also expects an authenticated Supabase user and raw invite token. It hashes the token, matches `parent_invites.token_hash`, upserts a `family_members` row with `role = 'parent'`, and marks the invite accepted.

Deploy both invite endpoints with JWT verification enabled:

```sh
supabase functions deploy accept-child-invite --project-ref "$SUPABASE_PROJECT_REF"
supabase functions deploy accept-parent-invite --project-ref "$SUPABASE_PROJECT_REF"
```

AI evidence review is handled by:

```text
supabase/functions/review-evidence/index.ts
```

The function expects an authenticated family member and a `submission_id`. It verifies child requests against the linked child profile, loads the private evidence image server-side, asks OpenAI for structured JSON, and stores the advisory result in `chore_submissions.ai_result`. If the model is unavailable, the photo remains submitted and receives an explicit parent-review result instead of a fabricated success. A parent decision is never overwritten by a late AI response.

Deploy it with:

```sh
supabase functions deploy review-evidence --project-ref pjvgtmxyxrfhabyuefne
```

Invoke it from the app with:

```json
{ "submission_id": "..." }
```

Due evidence deletion and expired-invite cleanup are handled by:

```text
supabase/functions/delete-submission-evidence/index.ts
supabase/functions/retention-cleanup/index.ts
```

`delete-submission-evidence` is a parent-authorized, idempotent endpoint for one due submission. `retention-cleanup` is a secret-protected batch worker that removes due Storage objects, clears both image paths, preserves the submission audit row, and expires old invite token hashes.

Deploy both functions, apply `0013_retention_cleanup.sql`, store a generated cleanup secret in Supabase Vault, and install the 15-minute cron schedule with:

```sh
./scripts/configure-evidence-cleanup.sh
```

The script reads `SUPABASE_DB_PASSWORD` when set, otherwise it uses the existing `ChaChing Supabase DB Password` Keychain item. The cleanup function is deployed with gateway JWT verification disabled because it authenticates scheduled requests using the separate `x-cleanup-secret` value.

To apply migrations without saving the database password:

```sh
export SUPABASE_DB_PASSWORD='...'
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0001_initial_schema.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0002_child_profiles_and_invites.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0003_parent_invites.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0004_family_bootstrap.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0005_parent_review_decisions.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0006_parent_settings_sync.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0007_evidence_policy_settings.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0008_task_nudges.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0009_chore_recurrence.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0010_task_deadlines.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0011_chore_lifecycle.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0012_evidence_deletion_schedule.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0013_retention_cleanup.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0014_submission_registration.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0015_automatic_family_maintenance.sql
psql "postgresql://postgres:${SUPABASE_DB_PASSWORD}@db.pjvgtmxyxrfhabyuefne.supabase.co:5432/postgres" \
  -f supabase/migrations/0016_child_excuse_requests.sql
```

## Next Slices

1. Accept Zoe's child invite, then smoke-test photo upload, on-device people blocking, AI review, and parent evidence viewing across two physical devices.
2. Add APNs-backed instant sync and parent-to-child nudges.
3. Add a dedicated child allowance-day celebration and parent closeout review before the payment request handoff.
4. Add orphaned-upload cleanup as a backstop for uploads interrupted before submission registration.
