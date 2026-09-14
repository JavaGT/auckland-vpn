# config-review — 2026-09-15 0930 wave (auckland-vpn)

Bounded pass: coordinator-native (no config-review child dispatched; the
3-child budget went to the hostile-review lane). Method: route-policy
re-verification, scheduler-receipt evidence, pain-journal ambient check,
opencode2 session-metadata sample. No repo config was edited — the evidenced
friction items are already decision tickets, so this wave appended live
evidence instead of duplicating them.

## Findings

1. **#54 — 5th consecutive run paid the stale-inline-policy cost.** Inline
   policy 2026-09-13.2 (verified_at 2026-09-13T02:08:05Z, stale_after 86400s)
   was ~19.5h past its window at the 09:30:49+12:00 dispatch. Re-verified both
   routes used this wave against ~/.config/opencode/MODEL-ROUTING.md:32-41 —
   all pairs match the inline table (no misroute), but the absolute-freshness
   gate keeps expiring daily while the underlying table is stable. Evidence
   appended to #54 (comment 5671129603). The scheduler-side fix proposed
   there remains the root-cause remedy.
2. **#60 — 4th consecutive receipt filed under `unsupplied-`.** Scheduler
   supplied no run_id/attempt again; receipt
   artifacts/automation-receipts/2026-09-15/unsupplied-20260915T0930-attempt-1-auckland-vpn-0930.md.
   Evidence appended (comment 5671129937); decision question unchanged.
3. **No new session friction found.** `opencode2 api get /api/session`
   metadata sample (8 most recent): this wave's hostile-review child completed
   normally; remaining titles belong to unrelated fleet work. No rescue
   follow-ups, stalled children, or late gate failures for this repo in the
   sampled window.
4. **Pain journal verified live and clean** (ambient pain-journal pass):
   standing header intact, mined-history map current through 2026-09-13, no
   unmined entries. One honest line appended this wave (python3 lacks pyyaml —
   one wasted command before switching to ruby); it also corroborates the #20
   observation that no local YAML-check tooling is preinstalled.

## What I did not look at

- Full opencode.json ↔ MODEL-ROUTING.md consistency check (#61 owns the
  evaluate question).
- Hook execution behaviour (#57 owns the opencode2-children guard gap).
- Transcripts, message bodies, secrets — metadata only.
