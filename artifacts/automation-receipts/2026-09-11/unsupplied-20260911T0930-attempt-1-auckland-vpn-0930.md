# Automation receipt — auckland-vpn — 2026-09-11 09:30 slot

{"schema_version":1,"run_id":"unsupplied-20260911T0930","attempt":1,"status":"success","failure_class":"none","time_box":"completed-within-budget","started_at":"2026-09-11T09:30:55+12:00","finished_at":"2026-09-11T10:01:30+12:00","next_action":"Owner decides #40 (monitor deep-probe config on-ramp: doctor-only line vs config-file keys vs document-only); #21 follow-up sweep on 2026-09-17 verifies #38/#39 fixes stuck","evidence":[{"path":"artifacts/automation-receipts/2026-09-11/unsupplied-20260911T0930-attempt-1-auckland-vpn-0930.md","kind":"artifact"},{"path":"gh:JavaGT/auckland-vpn#38","kind":"ticket"},{"path":"gh:JavaGT/auckland-vpn#39","kind":"ticket"},{"path":"gh:JavaGT/auckland-vpn#40","kind":"ticket"},{"path":"4e885f6","kind":"check"},{"path":"tests/run-tests.sh","kind":"check"}]}

Note: the scheduler supplied no run_id/attempt in the prompt or environment; the value is derived from
the slot timestamp (0930) and marked `unsupplied-` rather than fabricated to look scheduler-issued.

## Attempt 1 — 2026-09-11T09:30:55+12:00 (single attempt, no recovery)

- Wave: config/doc drift + friction sweep; shell/YAML surface kept safe.
- Admission: all 3 playbooks admitted (quick-scan, config-review, pain-journal). Discovery ran inline
  (repo ~3.2k lines); review/validation delegated to 3 background `opencode2 run --auto` children on
  route opencode/muse-spark-1.3-contributor-free (child budget 3/3 used, no retries, no fallback needed).
- Prior context honored: #22–#33 (2026-09-10 quick-scan), #34 (closed, fix 51873aa), #17/#18 (closed),
  #35/#37/#21/#20/#1 open — no duplicates created; yesterday's "not looked at" list re-checked: all
  items manual-only, audit-covered, or already folded into #22/#23.

### Playbook results

- quick-scan: **complete** — hotspots: full wrapper (2034 lines), tests/run-tests.sh (895, changed by
  51873aa), README, CI YAML, consults. Three NEW findings, all ticketed with file:line evidence:
  - #38 [Strong, docs-drift] start refuses without the helper (auckland-vpn:1103-1106) while README,
    usage(), print_sudoers_hint, cmd_doctor promised "asks for your Mac password once"; the ask-once
    fallback (1130-1136) needs the helper to exist. Docs fixed, code correct per audit. CLOSED.
  - #39 [Worth exploring, docs-drift] monitor deep probes require VPN_HEALTH_HOST/VPN_HEALTH_IP/
    VPN_DNS_SERVER — read but never assigned/documented; out of the box only dead-healing fires.
    README truth-up documented default + the three knobs. CLOSED.
  - #40 [Speculative, evaluate] first-class deep-probe on-ramp (config keys / doctor line). OPEN —
    implementation explicitly NOT the todo; consultant verdict recorded.
- config-review: **complete** — findings were exactly the two README drifts (README is the declared
  "full behaviour reference" per AGENTS.md); fixes applied directly in 4e885f6. Verification folded
  into the standing #21 follow-up (due 2026-09-17, comment added).
- pain-journal: **complete, no new findings** — journal live; 4 prior entries (2026-09-10) all mined
  by docs/reports/2026-09-10-pain-journal.md; one honest new entry appended this session (zcode Read
  tool garbled a file range; re-verified with grep before ticketing). No new themes → no ticket
  manufactured.

### Commits

- 4e885f6 "Docs truth-up: start needs the helper; monitor deep probes are opt-in (#38, #39)"
  (README.md + auckland-vpn only; diff --stat verified clean of foreign files)
- receipt commit (this file) — artifacts/automation-receipts/…-attempt-1-….md

### Reviews (all read-only, background, opencode2 run --auto)

- Hostile reviewer: APPROVED on all three lenses (docs-drift / shell safety / test honesty) with
  file:line evidence; independently ran the suite (21 passed / 0 failed); confirmed no residual
  start-without-helper text repo-wide and no behaviour change in the diff.
- Consultant A: AGREE — docs-only right for #38; no-helper path would reintroduce the audit-rejected
  arbitrary-root execution via --script= (auckland-vpn:778-786, docs/consults/test-architecture.md:88-90).
- Consultant B: AGREE — docs-only for #39; #40 wiring worth evaluating, doctor-only first may suffice.
- Reconciliation: full agreement, no split; verdicts recorded on #38/#39/#40.

### Focused checks

- tests/run-tests.sh: 21 passed / 0 failed — run after edits and re-run after the final comment fix;
  independently re-run by the reviewer. bash -n auckland-vpn clean.

### Failure class / blocker / incomplete

- failure_class: none. No dispatch failures, no route fallbacks, no timeouts; all children completed.
- Blocker: none blocking. Note: scheduler did not supply run_id/attempt (derived value used, marked).
- Incomplete work: none. Open items are decisions, not tasks: #40 (owner decision), #21 (scheduled
  2026-09-17 sweep), #37 fork reconciliation, #35/#22-#33 as previously ticketed.
- time_box: completed-within-budget (~31 min of 50).

### Progress log

  - 09:30 started; git clean at 51873aa.
  - 09:41 tickets #38/#39/#40 created and claimed (file:line evidence in each body).
  - 09:47 commit 4e885f6 (README.md + auckland-vpn); suite 21/0 twice (before and after final comment fix).
  - 09:48 3 background review children dispatched (reviewer + 2 consultants, same candidate pack).
  - 09:56 verdicts reconciled: reviewer APPROVED ×3 lenses; consultants AGREE/AGREE. #38/#39 closed
    with evidence; #40 updated (stays open, evaluate framing); #21 annotated for the 09-17 sweep.

### Addendum — push deferred (10:05)

- origin/main and main have DIVERGED: 13 local-only commits (incl. 4e885f6, 9e0e4e2) vs 2 remote-only
  (pre-burst install.sh/update lineage). This is open decision ticket #37 — deciding the canonical
  lineage is not this wave's call; no push, no merge, no force. Both new commits are safe on local main.
