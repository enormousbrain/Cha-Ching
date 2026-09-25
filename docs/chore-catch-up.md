# Missed Chore Catch-Up

Children can open Catch Up from Today or a grouped local notification. The list shows
missed occurrences, oldest first, across unconfirmed allowance periods. New occurrences
of the same chore and confirmed periods are excluded. Dates distinguish repeated chores.

Missed occurrences are collapsed into groups by child, chore definition, and scheduled
hour/minute. Expanding a group exposes dated checkboxes and Select All. Up to 100 items
can be submitted together; larger groups offer Select First 100.

"I did it, but don't have a photo" opens a confirmation sheet with the selected dates
and an optional note. This is available even for normally photo-required chores. Claims
are explicitly labeled "Reported done without photo" for parents and do not run AI review.
Submitted items leave Catch Up and appear in the child's Awaiting Review section.

The parent's Pending Approvals queue spans all children in the family, grouped by child,
chore, and scheduled time. It includes photo submissions, no-photo claims, and excuse
requests. Photos can be opened, and notes are visible before selecting dates. Approve,
Excuse, and Reject operate on selected dates within one group after confirmation.
The allowance overview is collapsible so pending approvals stay near the top of Review.
Bulk claims and decisions are atomic: a stale, unauthorized, or locked item rejects the
whole operation. Repeating the same pending no-photo claim does not duplicate submissions.

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
Migration `0023_grouped_chore_claims.sql` was applied on September 24, 2026. It adds
the reported-done note and the two atomic bulk RPCs without changing existing chore data.

- Swift reminder tests cover daily limits and quiet hours.
- `supabase/tests/catch_up_submissions.sql` runs in an empty disposable PostgreSQL database
  and checks ownership, duplicate submissions, deductions, parent decisions, and settled locks.
- Device smoke test: open a missed chore as child, submit proof, confirm it leaves Catch Up,
  then approve as parent and check the balance after refresh.
- With missed chores and alerts enabled, check the grouped notification opens Catch Up.
- After a successful sync, relaunch offline and verify the widget keeps its balance;
  sign out and verify it clears when WidgetKit reloads.
- `supabase/tests/grouped_chore_claims.sql` checks required-photo claims, ownership,
  idempotent retries, bulk approvals/rejections, stale-selection rollback, and settled locks.
- Debug simulator previews are opt-in through `CHACHING_GROUPED_PREVIEW=child|parent`;
  `CHACHING_GROUPED_EXPANDED=1` opens groups with two items selected. These fixtures do
  not publish widget data and are not available in Release builds.
