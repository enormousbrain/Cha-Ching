# Privacy and Account Settings

Implemented September 24, 2026. This covers app behavior; public policy text and App Store disclosures still need the release review.

## In the App

- Parents: Family > Privacy & Account.
- Children: the account icon on Today > Privacy & Account.
- A parent authorizes photo sharing for the family. Each uploader also accepts version 1 of the disclosure before capturing/uploading evidence.
- The disclosure names Supabase (storage), OpenAI (AI review), family parent access, deletion settings, and the limitations of on-device people detection.
- A parent's withdrawal clears all family photo permissions. A child's withdrawal clears only their own permission. New uploads stop; existing evidence follows retention settings.
- No-photo completion reports remain available for parent review.
- Storage policies and submission triggers enforce consent, assigned-child ownership, and immutable evidence objects. A UI bypass cannot authorize an upload.

## Account Deletion

`delete-account` validates the Supabase JWT with Auth and ignores any client-supplied user ID. The user must explicitly type DELETE in the app. The backend uses only the authenticated user ID.

- Deleting a child removes their profile, chores, reviews, evidence, goals, allowance periods, and ledger history. Siblings remain.
- Deleting a parent when another parent remains preserves shared family and financial records, anonymizes account attribution, and removes membership, their invites, and push tokens.
- Deleting the final parent deletes the family and all its child data. It does not delete other people's Auth accounts.
- Parent deletion is serialized with a family row lock. Concurrent parent deletions cannot leave a family without a manager.
- Closed-period protections remain in place. Only service-authorized removal of a deleted parent's attribution may change retained settled records.
- Evidence paths are queued durably before database rows are removed. Storage is deleted through its API. Auth deletion happens after queued photos are gone. Failed attempts remain queued and are retried by the existing 15-minute cleanup worker.
- Refresh tokens are revoked and the pending-deletion account is banned. Membership removal and deleted child linkage remove data access even for an existing access token. Rejoining while deletion is pending is rejected.
- Successful acceptance clears local account data, notifications, home reminders, and widget state. A live family account was NOT deleted during testing.

## Apple Sign-In Revocation

Native Apple login currently retains no Apple refresh token. The deletion screen can request a fresh authorization code. The Edge Function exchanges it, verifies the Apple token issuer/audience/subject against the authenticated account, and calls Apple's revocation endpoint. Tokens and authorization codes are not logged or stored.

Configure these Supabase secrets before testing automatic revocation:

- `APPLE_SIGN_IN_PRIVATE_KEY`: contents of a Sign in with Apple `.p8` key (not the APNs key).
- `APPLE_SIGN_IN_KEY_ID`: that key's ID.
- `APPLE_SIGN_IN_TEAM_ID`: `2LF847PDLK`.
- `APPLE_SIGN_IN_CLIENT_ID`: `com.artofsullivan.chaching` for native iOS authorization codes.

Keep the private key out of git. Without this configuration, a fresh code, or a working Apple endpoint, account deletion still proceeds and the app instructs the user to remove ChaChing in iPhone Settings > their name > Sign in with Apple. Automatic revocation remains a public-release verification item.

References: [Apple account deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/), [Apple token revocation and missing-token handling](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple).

## Abandoned Uploads

Every cleanup run claims at most 100 unreferenced Storage objects older than 24 hours. Registered images and thumbnails, including pending reviews, are excluded. A per-path transaction lock coordinates cleanup claiming with photo registration. A claimed or missing image cannot later be registered; the child must take another photo. Failed cleanup attempts rotate behind untouched work.

## Deployment and Website

- Migration: `0024_privacy_and_account_deletion.sql`.
- Applied to the linked Supabase project on September 24, 2026; both functions below were deployed. The existing 15-minute retention cron was confirmed active. An unauthenticated deletion request was rejected.
- Edge Functions: `delete-account` and `retention-cleanup`. Both use `--no-verify-jwt` at the gateway; delete-account validates the user's JWT internally, while retention-cleanup requires its existing cleanup secret.
- Existing builds cannot upload after server consent enforcement activates. Install the new build and authorize photo sharing before testing a new photo.
- Public pages: `/cha-ching/privacy/` and `/cha-ching/support/`, with `/cha-ching/information.css`.
- Canonical copies are under `Website/enormousbrain/cha-ching/`. Matching files are in the local enormousbrain.com source and included by its existing webpack copy rule.
- The static site was built locally. Upload the resulting `dist/cha-ching` privacy/support directories and CSS to GoDaddy. In-app Privacy Details is available before website deployment.

## Verification

- `supabase/tests/privacy_and_deletion.sql` builds real application tables in a disposable PostgreSQL database with stubbed Auth/Storage. Tests cover server consent, withdrawal, unauthorized access, orphan exclusions, deletion retries, settled history retention, child/sibling isolation, and last-parent deletion.
- `deno test --allow-env supabase/functions/_shared/privacy-cleanup_test.ts` covers Storage failures, database failures after Storage success, Auth deletion retries, and missing Apple authorization.
- iOS Debug and Release simulator builds, Swift core tests, and local website build.
- Still verify on disposable signed-in device accounts: first-upload consent, withdrawal on another device, deletion UI and local widget clearing, and automatic Apple revocation after key configuration.
