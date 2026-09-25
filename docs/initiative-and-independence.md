# Initiative and Independence

Updated September 25, 2026.

## Product Direction

Success means more self-directed follow-through with less prompting, including eventually not needing the app. Do not optimize for visits, notification responses, streaks, or reliance. Describe this as practice in planning and follow-through, not a claim about brain development or a clinical intervention.

Recognize noticing, planning, preparation at an appropriate time, and following through. Earlier is not always better: pet feeding, pickup, and other time-sensitive responsibilities should happen at the right time. Needing reminders again is not failure.

## First Slice: Implemented

- Separate child-scoped gold-star balance, visible from child Today and parent Review. Stars persist across allowance periods and have no expiry or streak requirement.
- Parent awards one star with a specific recognition reason. Shortcuts include noticing a need, making and following a plan, remembering without a reminder, and preparing ahead.
- Awards can be linked to an approved chore occurrence, with one award per occurrence enforced server-side. General everyday initiative can be recognized without a chore.
- Recent history shows the latest 100 entries; the balance is calculated over the complete server ledger, not truncated history.
- Five stars can be requested as a credit against a positive missed/rejected-chore deduction in an unconfirmed allowance period. A parent must approve each credit and can decline safety-sensitive responsibilities.
- Approval atomically checks the remaining balance, spends five stars, and voids the deduction. It does not change the chore to completed. Declining costs nothing. One request per occurrence avoids repeated requests after a parent decision.
- Row-level security limits children to their own records and parents to their family. Client-side direct writes are denied; RPCs enforce authorization and duplicate/spending rules.
- Child/family deletion cascades reward records; deleted award-givers are detached from retained family records.
- No new notifications, app-open rewards, automatic early-completion rewards, rankings, or star loss for inactivity.

Migration `0025_initiative_stars.sql` was applied to the linked Supabase project on September 25. It is additive and awards no live stars. Existing migration history is not populated in the CLI table, so do not blindly run `supabase db push` over all existing migrations; this migration was applied directly in one transaction.

## Follow-Up Slices

- Optional notification-based invitations to plan, replacing selected nonurgent reminders rather than adding alerts. This requires explicit family preferences and must keep urgent responsibilities direct.
- Parent/child-controlled reduction of prompting, with an easy way to restore support. Never infer independence from not opening the app.
- Optional per-chore credit eligibility and family-configurable reward cost. The initial cost is fixed at five in both the SQL contract and `InitiativeStars.creditCost`; changing it needs a versioned policy, not just a label change.
- Parent-confirmed recognition suggestions for proactive completion; no timestamp-only automatic award.
- Gradually retiring rewards and routines when the family decides support is no longer needed.
- Broader AppStore mutation/refresh concurrency integration coverage remains a release-readiness item.

## Verification

- Swift tests cover balance scoping and credit eligibility, including settled, voided, submitted, and previously requested chores.
- Disposable PostgreSQL tests cover authorization, RLS read isolation, denied direct writes, idempotent awards/requests/approval, duplicate chore awards, insufficient funds, unchanged completion status, declined requests, and settled-period protection.
- Before release, test on separate parent/child phones: award stars, wait for refresh, request credit, approve or decline, and confirm both the star history and allowance/widgets update. A star has no cash value until an approved credit reverses a specific deduction.

No scientific effectiveness claim has been evaluated in this slice.

## Second Slice: Self-Chosen Plans

- Optional, child-initiated "What do you want to handle next?" on Today. It never opens automatically and has a Not now action.
- Up to three real, unplanned chores due later today, in chronological order. Completed, submitted, paused, archived, missing, settled, other-child, overdue, and future-day tasks are excluded.
- Any offered choice is accepted. There is no correct-answer score, star for tapping, or reward for checking in repeatedly.
- The child chooses now, the due time, or a time in between. Planning does not change the deadline, verification requirement, or existing reminders. It does not imply that earlier is better.
- Active plans appear on Today and task detail. The child can change or clear an open plan without losing stars. Submitted tasks preserve the plan as context for parent review.
- Grouped family approvals and individual reviews show the self-chosen time and last-saved timestamp. An approved planned chore offers parent recognition, preselecting that occurrence; normal one-star-per-occurrence rules apply. Submission timestamps are not treated as proof of when real-world work happened.
- Supabase enforces child-only plan writes, family/child read isolation, valid times, and no edits after submission or allowance confirmation. No star, ledger, or notification mutations occur from saving a plan.
- Migration `0026_child_chore_plans.sql` deployed September 25. Client includes plans in normal family refresh and clears them at sign-out.

Verification: 55 Swift tests pass. Disposable database tests cover plan authorization, time bounds, retry/update/cancel behavior, no automatic stars, RLS, parent visibility, denied direct writes, paused tasks, submitted tasks, and confirmed periods. Physical-device parent/child sync and the complete plan-to-recognition interaction still require a smoke test.
