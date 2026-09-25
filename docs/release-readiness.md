# Release Readiness

Updated September 25, 2026. This is a release gate, not a list of completed features.

## Implemented, Awaiting Device Verification

- Background refresh registration delivers the MainActor callback on the main queue. The expiration handler is Sendable. Xcode crash groups, including build 22, pointed to the registration callback's actor-isolation trap.
- Remote child selection persists per signed-in user and family. Refresh requests execute serially. Sign-out invalidates pending refresh publication.
- Child accounts require their own linked profile; no sibling fallback is permitted by the client selector. Server RLS remains the authorization boundary.
- Template imports stop on failure, preserve unfinished selections, and reuse IDs during retries within the same sheet. Successful entries are removed from the selection. Closing and reopening the sheet is not a durable import retry mechanism.

## Required Before Public Release

- [ ] Verify [initiative stars and credit approvals](initiative-and-independence.md) on separate parent/child phones. Stars recognize independence, not app engagement; migration 0025 is deployed.
- [ ] Verify self-chosen plans across child/parent devices, including changing/clearing a plan, submission, parent review context, and recognition. Migration 0026 is deployed; existing notifications are unchanged.

- [ ] Publish a new build with the crash fix and verify background execution on physical devices; monitor new crash reports.
- [ ] Verify two-child switching during polling, relaunch, failed requests, and sign-out. Add AppStore integration tests for refresh ordering and mutation/refresh overlap; current selection tests cover only the core selection policy.
- [ ] Fix local-preview child switching, which currently filters arrays destructively and does not restore a complete per-child context.
- [x] Replace the current-balance request with server-confirmed closeout, historical reviews, explicit paid status, and idempotent settlement. See [allowance closeout](allowance-closeout.md).
- [ ] Verify the complete closeout and request flow on parent and child devices. Sending a message must never mark an allowance paid automatically.
- [x] Add account deletion with explicit co-parent, last-parent, and child-data handling and authenticated backend enforcement. See [privacy/account settings](privacy-account-settings.md).
- [ ] Configure the separate Sign in with Apple private key and verify token revocation on a disposable account; verify account deletion and widget clearing on physical devices.
- [x] Add privacy/support links and explicit server-enforced cloud-photo-sharing consent before upload.
- [ ] Upload the privacy/support website pages and verify the consent, withdrawal, retention, deletion, and disclosure flow on physical devices.
- [x] Bound all local reminder categories together, deduplicate location regions, reserve capacity for home reminders, and check cached chore windows before arrival alerts. See [reminder reliability](reminder-reliability.md).
- [ ] Verify background arrival reminders with optional Always permission on a physical child device, including denial/revocation, snoozes, completion, expiry, and account switching.
- [ ] Test permission denial, offline/reconnect, timezone/DST changes, weekly/biweekly rollover, and negative carryover.
- [ ] Test server isolation between two families and between children, including invites, photo access, review actions, and widgets.
- [x] Add orphaned-photo cleanup for interrupted uploads, excluding registered evidence and coordinating with registration.
- [ ] Verify grace periods and dispute holds with physical-device evidence submissions.
- [ ] Replace unsafe missing-chore indexing with an explicit missing/deleted-chore state.
- [ ] Complete App Store privacy disclosures, review credentials/instructions, screenshots, support pages, service cost estimates, and the pricing decision.

## Verification This Pass

- Swift package: 55 tests passed, including planning choices, star balance/credit eligibility, reminder budgets/arrival windows, grouped catch-up, parent selection persistence policy, family scoping, deleted preference fallback, and child linkage isolation.
- iOS Simulator Debug and Release builds passed; reminder settings were visually checked in light and dark mode.
- Privacy/account deletion migration 0024 and backend functions were deployed during the preceding privacy slice. This reminder slice requires no database migration. No TestFlight upload was performed.
- Template partial-failure UI and physical-device background behavior still need manual verification.
