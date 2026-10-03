# quick-scan — 2026-09-19 (auckland-vpn, manual catch-up)

Catch-up for the skipped 09-18 + 09-19 0930 automations (computer asleep both
mornings). Read-only scan of hotspots since the last committed wave (0908222,
2026-09-17); AGENTS.md/README read first; known-open anti-list honoured (44
open issues, incl. #80/#81/#82 filed this morning by the Account-2 second
pass) — no re-derivations. Candidate findings re-verified with sed/grep at
exact lines and reproduced live (/tmp + real binary, no repo mutations).

## Findings (ranked strength x leverage)

### 1. Strong — origin's pid-file pipefail fix (2b9e90f, Sep 4) was never ported; setup aborts on a capable binary → #83, implemented this wave

`openconnect_supports_pid_file` (auckland-vpn:226-229) kept the pre-fix form
`openconnect --help 2>&1 | grep -q -- '--pid-file'` under `set -euo pipefail`
(:24, :471). The real binary exits 1 after help (verified live:
`/opt/homebrew/bin/openconnect --help` → exit 1), so the pipeline exits 1 even
on a match — reproduced. Impact: `cmd_setup` dies with false "lacks --pid-file
… Run: brew upgrade openconnect" (:900-901); setup-sudo bakes
`OC_HAS_PID_FILE=0` into the root helper (:420-421, :469), degrading stop to
non-exact kill (:617). Test honesty: the stub's `--help` branch exited 0
(tests/run-tests.sh:64-67) and the probe had no direct test, so the suite
stayed green. Instance of the #37 reconcile drift.

Disposition: #83 filed + claimed; fixed in 95c4bdc (probe captures help with
`|| true` before grep; stub faithful exit 1; regression test
test_helper_bakes_pid_support_despite_help_exit_1 asserts OC_HAS_PID_FILE=1).
Full suite 26 passed / 0 failed. Ticket left open for the hostile review round
(reviewers deferred this wave — see config-review report, #54/#66).

### 2. Observed — #82's user-facing dead citation reworded this wave (801613a)

#82 (filed this morning by the Account-2 second pass) was claimed and its
"inline the actionable sentence" branch implemented: cmd_diagnose's REALM
warning now states the audit-verified mechanism (/client URL path becomes
realm 'client' only via a gateway redirect containing realm=client) and drops
the repo-path citation that installed users cannot resolve. Diagnose-focused
and full suites green. Still open for the deferred hostile review round.

### 3. Observed, no new ticket — main/origin divergence is still the largest standing drift

main is 52 ahead / 2 behind origin (#37, upd 09-09). The only origin-only
script hunk (2b9e90f) is now ported (finding 1); 17946e3 (install.sh one-liner
+ update command lineage) remains unreconciled and unexamined this wave —
that decision belongs to #37, not a quick-scan.

## What I did not look at

- monitor state machine internals and helper privilege paths (open #22/#23/#28
  lanes; hostile review required for any privilege-path change).
- docs/consults content drift (#77 lane) and README behaviour claims (#76).
- installed-binary parity (#33) and origin install.sh/update lineage
  (17946e3) beyond the single pid-file hunk.
