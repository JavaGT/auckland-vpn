# config-review — 2026-09-20 (auckland-vpn, read-only discovery child)

Scope: agent-facing configuration in this repo only — AGENTS.md, README.md
(minus #76/#77), tests/run-tests.sh ergonomics, artifacts/ conventions — plus
mining of the 2026-09-1x wave reports and receipts for repeated friction.
Anti-list honoured: all 44 open issues (incl. #54/#66/#67/#68/#70/#73,
#75-#83) treated as tracked, not re-derived. No issues filed, no edits applied.
The 2026-09-20 0930 receipt in artifacts/automation-receipts/ is another
agent's live output — read only, left untouched.

## Findings

### F1 (Strong) — The "reconcile review verdicts before closing" rule is unwritten; two waves relied on it

Evidence:
- artifacts/automation-receipts/2026-09-19/manual-catchup-20260919-attempt-1-auckland-vpn-0930.md, "Incomplete work / checkpoint": "Tickets left OPEN deliberately (repo rule: reconcile review verdicts before closing)."
- artifacts/reports/2026-09-19/config-review.md:45-52 defers the #83/#82 review with the checkpoint "close #83/#82 on APPROVED / route FIX-FIRST fixes back to the tickets"; the 2026-09-20 receipt (line 12) adopted that checkpoint and again held the tickets open.
- `grep -rn "reconcile\|verdict" AGENTS.md README.md docs/` → no rule text anywhere; AGENTS.md:42 names "review verdicts" only as an artifacts/reviews/ pointer.

Impact: an agent working from AGENTS.md alone closes a ticket the moment its
implementation commit lands, destroying the pending-review checkpoint that
consecutive waves (09-19, 09-20) deliberately preserved for #83/#82. The rule
currently survives only inside receipts and wave reports a fresh agent is not
pointed at.

Proposed edit — AGENTS.md, "Agent hygiene" section, new bullet after the
artifacts map bullet:

> - Implemented wave work keeps its tracker ticket open until the hostile
>   review verdict is reconciled: close on APPROVED; route FIX-FIRST fixes
>   back to the ticket. A review deferred by a dispatch blocker leaves an
>   exact next action in the wave report and the receipt's `next_action`.

Disposition: apply now (3 lines; pure codification of observed practice).

### F2 (Minor) — AGENTS.md:5-6 "Installed as /opt/homebrew/bin/auckland-vpn" lacks a staleness caveat

Evidence: `cmp -s /opt/homebrew/bin/auckland-vpn ./auckland-vpn` → DIFFERS
(re-verified this pass); #33 open — the installed copy is a stale
pre-hardening build.

Impact: AGENTS.md states the installation as plain fact. An agent that checks
live behaviour against the installed binary (the natural reading of
"installed as") observes pre-hardening behaviour and can manufacture false
findings or false confidence. #33 owns the redeploy; the agent-facing half of
that gap is this uncaveated sentence.

Proposed edit — AGENTS.md:5-6, append one clause:
"…installed as `/opt/homebrew/bin/auckland-vpn` (that installed copy is a
stale pre-hardening build — verify behaviour against the repo script, not the
installed binary; #33)."

Disposition: apply now (one clause), or land it with #33's redeploy commit if
the coordinator prefers the caveat and the fix to ship together.

### Ticket-only external context (one line, out of workspace)

- 09-20 review dispatch failed with deepseek `Insufficient Balance` after the
  route verified clean — distinct from #66's dead-model-id failure class;
  owner account action needed before the deferred #83/#82 review can run.

## Verified clean (explicit per scope area)

- **AGENTS.md pointer map** — every named target resolves:
  `docs/consults/{openconnect-audit,test-architecture,reliability}.md` exist;
  `tests/run-tests.sh` exists and is executable;
  `artifacts/{reports,reviews,automation-receipts}/` all exist (reviews holds
  3 hostile verdicts — the map added in 8ad4105 is true);
  `docs/reports/` is gone and the #58 consolidation note (AGENTS.md:41-42)
  matches git log 5c69bb6; `[quick-scan]`/`[config-review]` prefixes both
  live in the open-issue list (#83, #75); `.github/workflows/tests.yml`
  exists locally (#48 tracks the origin/never-ran half — not re-derived).
- **README as behaviour reference** — no drift from this week's only two code
  commits (95c4bdc: script+tests only; 801613a: one script line). Dispatch
  case auckland-vpn:2144-2157 matches README's command list exactly
  (setup, setup-sudo, start, stop, restart, status, monitor, log, pin,
  doctor, diagnose; bare/unknown → usage, exit 2 at :2152-2153); `pin` exists
  (:1843); the doctor advisory-WARN contract (README.md:98-101) matches the
  script (:1860, :1936 — WARN/INFO never affect the exit code); the Realm
  evidence section (README.md:178-181) matches the post-#82 warning wording
  at :2079 — now more accurate than before. #76/#77 untouched per anti-list.
- **tests/run-tests.sh ergonomics** — clean; no new misread traps. Focused
  substring run matches AGENTS.md:25-26 and README.md:262-263 (#59's fix
  landed); 26 tests; no-match exits 1 with a named message (:1010-1013);
  failed names repeat after the summary for log tails (:1019-1023, #49's
  fix); `run_test` scores the `.test-failed` marker, not just subshell exit
  (:958-960). #78/#79 own the known harness-honesty residue — untouched.
- **artifacts/ conventions** — reports in per-date dirs (every wave
  2026-09-10 → 2026-09-20 present), review verdicts flat in artifacts/reviews/
  (naming `<date>-<slot|sha>-hostile.md`), receipts in per-date dirs. The
  AGENTS.md map of the three trees is still true.

## Repeated friction mined from the 2026-09-1x waves

- Hostile-review round for 95c4bdc (#83) / 801613a (#82) deferred two waves
  running with different blockers: 09-19 stale inline route policy (#54),
  09-20 provider balance (above). F1's AGENTS.md bullet is the in-repo half
  of the fix; the blockers themselves are external (#54/#66, tracked).
- Checkpoints did not bounce: the 09-20 wave adopted the 09-19 checkpoint
  verbatim; the #73 one-shot unload rule has held since the incident (no
  stale fires in 09-19/09-20 receipts).
- `unsupplied-` receipt prefixes continue daily (#60, tracked).

## What I did not look at

- App code internals beyond the sections README claims rest on.
- docs/consults content drift (#77 tracks it).
- README status/log "latest attempt" claim (#76 tracks it).
- Everything outside this workspace: MODEL-ROUTING.md, opencode.json, skills,
  hooks, LaunchAgents, pain-journal contents (cited only via receipts).
- Open issues other than as anti-list context; closed issues beyond #49/#59
  history for harness ergonomics.
- The untracked 2026-09-20 automation receipt as anything but read-only
  evidence (another agent's live output).
- CI runner behaviour (#48: zero runs exist).
