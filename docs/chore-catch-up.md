# Missed Chore Catch-Up

Children can open Catch Up from Today or a grouped local notification. The list shows
missed occurrences, oldest first, across unconfirmed allowance periods. New occurrences
of the same chore and confirmed periods are excluded. Dates distinguish repeated chores.

Late photo and no-photo submissions use the usual parent review flow and evidence rules.
Submission and AI review do not restore deductions. Parent approval restores the deduction;
rejection leaves it in place. Confirmation locks the period against new submissions.

## Reminder Timing

After the child's app syncs missed chores, it schedules at most one grouped catch-up
notification per local day: 5 PM, or one minute later if already between 5 PM and 8 PM.
After 8 PM it schedules for 5 PM the next day. Refreshing the app does not postpone an
existing alert. Emptying the catch-up list cancels it. Parent devices do not get this alert.

This uses the device's notification permission and its latest synchronized data. It does
not guarantee a reminder for newly missed chores while iOS prevents background refresh.
Opening the alert refreshes the list before showing current results.

## Widget Cache

Only a successfully loaded allowance with an authenticated owner is published. Startup
and failed refreshes preserve that owner's last balance. Sign-out clears it. Gallery
previews and missing caches show a neutral state; a real zero-dollar balance remains valid.
Older caches without an owner are ignored until the next successful sync.

## Verification

Migration `0022_catch_up_submissions.sql` was applied to Supabase on September 22, 2026.
Deployment changed submission rules; it did not submit or approve any real chores.

- Swift reminder tests cover daily limits and quiet hours.
- `supabase/tests/catch_up_submissions.sql` runs in an empty disposable PostgreSQL database
  and checks ownership, duplicate submissions, deductions, parent decisions, and settled locks.
- Device smoke test: open a missed chore as child, submit proof, confirm it leaves Catch Up,
  then approve as parent and check the balance after refresh.
- With missed chores and alerts enabled, check the grouped notification opens Catch Up.
- After a successful sync, relaunch offline and verify the widget keeps its balance;
  sign out and verify it clears when WidgetKit reloads.
