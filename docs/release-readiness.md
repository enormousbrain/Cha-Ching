# Release Readiness

Updated September 21, 2026. This is a release gate, not a list of completed features.

## Implemented, Awaiting Device Verification

- Background refresh registration delivers the MainActor callback on the main queue. The expiration handler is Sendable. Xcode crash groups, including build 22, pointed to the registration callback's actor-isolation trap.
- Remote child selection persists per signed-in user and family. Refresh requests execute serially. Sign-out invalidates pending refresh publication.
- Child accounts require their own linked profile; no sibling fallback is permitted by the client selector. Server RLS remains the authorization boundary.
- Template imports stop on failure, preserve unfinished selections, and reuse IDs during retries within the same sheet. Successful entries are removed from the selection. Closing and reopening the sheet is not a durable import retry mechanism.

## Required Before Public Release

- [ ] Publish a new build with the crash fix and verify background execution on physical devices; monitor new crash reports.
- [ ] Verify two-child switching during polling, relaunch, failed requests, and sign-out. Add AppStore integration tests for refresh ordering and mutation/refresh overlap; current selection tests cover only the core selection policy.
- [ ] Fix local-preview child switching, which currently filters arrays destructively and does not restore a complete per-child context.
- [ ] Replace the current-balance allowance request with a server-finalized period closeout. Resolve pending reviews/disputes, let a parent confirm the amount, record paid status, and guard duplicate settlement. Sending a message must never mark an allowance paid automatically.
- [ ] Add account deletion with an explicit family-owner/child-data retention policy and authenticated backend enforcement.
- [ ] Add privacy/support links and explicit cloud-photo-sharing consent before upload. Check retention, deletion, and disclosure behavior end to end.
- [ ] Bound all reminder categories together, deduplicate location regions, reserve capacity for home reminders, and prevent stale/future chore arrival alerts.
- [ ] Test permission denial, offline/reconnect, timezone/DST changes, weekly/biweekly rollover, and negative carryover.
- [ ] Test server isolation between two families and between children, including invites, photo access, review actions, and widgets.
- [ ] Add orphaned-photo cleanup for interrupted uploads and verify grace periods and dispute holds.
- [ ] Replace unsafe missing-chore indexing with an explicit missing/deleted-chore state.
- [ ] Complete App Store privacy disclosures, review credentials/instructions, screenshots, support pages, service cost estimates, and the pricing decision.

## Verification This Pass

- Swift package: 37 tests passed, including parent selection persistence policy, family scoping, deleted preference fallback, and child linkage isolation.
- iOS Simulator Debug build passed.
- No production database migration or TestFlight upload was performed in this pass.
- Template partial-failure UI and physical-device background behavior still need manual verification.
