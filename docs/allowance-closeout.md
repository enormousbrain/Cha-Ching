# Allowance Closeout

Parents use Earnings > History > a completed period. Complete any pending reviews, then confirm the amount. Confirm periods oldest first so carryover corrections flow into the next period before it is locked.

Confirmation snapshots the current ledger on the server. Open, submitted, and AI-reviewed chores block confirmation; missed chores retain their existing deductions unless a parent changes the decision. Confirmed periods cannot accept later ledger or task changes.

The child sees a payment request for each confirmed, positive, unpaid period. The message names the period and exact confirmed amount. Sending or sharing it does not change payment state. The parent separately records payment, or closes a zero-dollar period without payment. Payment recording stores the server timestamp and parent identity. Repeated confirmations and payment recordings return the existing record.

## Carryover

Rollover records the reduction applied to the following period. A late decision can change that reduction; confirmation adds one correction to the following period. Older periods must be confirmed first. At migration time, existing archived periods receive a baseline calculated from their current ledger and the family base allowance; pre-migration manual historical edits are not reconstructible from existing data.

## Verification

Migration 0021 was applied to the linked Supabase project on September 22, 2026 after a rolled-back schema validation. No existing period was confirmed or marked paid during deployment.

- Swift tests cover payment eligibility, exact confirmed amounts, paid suppression, and decoding older snapshots.
- `supabase/tests/allowance_settlements.sql` runs against an empty disposable PostgreSQL database. It creates its own minimal schema and applies migration 0021. It covers parent authorization, child/sibling/cross-family reads, anonymous denial, pending reviews, stale amount rejection, immutable periods, idempotent retries, late approval/rejection carryover, and zero-dollar closeout.
- Device smoke test: resolve a historical submission, confirm its amount, open the child's Earnings page, compose a request, cancel/send it, verify it remains unpaid, record payment from the parent device, and refresh the child to verify the request disappears.
- No money is transferred by these actions. In-flight messages already opened in Messages cannot be recalled by a later payment update.
