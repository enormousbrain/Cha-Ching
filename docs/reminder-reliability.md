# Reminder Reliability

Updated September 24, 2026.

## Scheduling

- One serialized coordinator schedules chore reminders, snoozes, catch-up, allowance, local parent nudges, and arrival alerts.
- The pending queue uses a conservative budget of 60, subtracting requests owned by other features. Immediate nudges/arrivals, allowance, and catch-up have priority; remaining capacity goes to chronological chore reminders.
- Chores sharing a reminder minute are grouped. Identical pending requests are retained rather than restarted on every poll.
- Requests carry the signed-in user, family, and selected child. Owner changes replace old requests; sign-out clears notifications, saved home, delays, and monitored regions.
- Completion, expiry, and schedule edits remove obsolete pending reminders when the app receives updated data. Foreground presentation also checks the latest cached owner and chore state.

## Optional Location Reminders

- Background arrival reminders use CLLocationManager region entry callbacks and require optional Always location authorization. Timed reminders do not require location access.
- At most 20 regions are monitored, subtracting other monitored regions. Co-located chores share a region; a deferred home reminder receives priority.
- Entry callbacks check the latest locally cached chore window. Future chores outside their lead window, expired chores, and active snoozes do not produce destination alerts.
- Already-alerted destination occurrences are excluded. Repeated callbacks reuse a deterministic notification identifier.
- Losing background location access or disabling home reminders converts outstanding home deferrals into a timed fallback before expiration where possible.
- No continuous GPS tracking or live location upload is introduced. An entry event is not proof a chore was completed, nor a guarantee that a child has left for a destination.

## Limits

iOS controls background launches, region entry delivery, and notification presentation. Force-quitting, disabled Background App Refresh, permissions, Focus, and system scheduling can delay or prevent alerts. Remote approvals cannot cancel offline cached reminders until state refreshes. Arriving early and remaining inside a destination does not create a new entry event at the due time; timed reminders remain the fallback. The local schedule covers 14 days and replenishes when the app refreshes.

## Verification

- 49 Swift tests pass, including combined queue priorities/capacity, deduplication, region sharing/capacity, home reservation, snoozes, future/expired arrival rejection, and existing DST/recurrence cases.
- Before release, test on a physical child device: allow notifications, keep location denied and confirm timed alerts; opt into Always and cross a destination boundary within the lead window; repeat after completion and expiry; snooze an alert; defer to home; revoke Always and verify fallback; switch accounts and confirm old alerts clear.
- Verify allowance-day and catch-up notifications alongside a densely populated chore schedule, and retry nudges after reconnecting.

Apple reference: [Monitoring geographic regions](https://developer.apple.com/documentation/corelocation/monitoring-the-user-s-proximity-to-geographic-regions).
