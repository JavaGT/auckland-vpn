# Config-review report — auckland-vpn (2026-09-11, run auckland-vpn-1000)

Playbook child: improve how agents work in this repo (configuration / docs /
skills surface), not app code. Evidence sources: OpenCode session metadata
(`opencode2 api get /api/session`, 2 pages, no transcript exports), open
tracker issues #20–#40, prior wave reports, pain journal, and direct inspection
of AGENTS.md / README.md / docs/consults/ / tests/run-tests.sh /
.github/workflows/tests.yml. Environment at start: branch main clean (one
untracked coordinator receipt file, left untouched), ahead 14 / behind 2 vs
origin (#37).

## Findings and what was done

### F1 (Strong) — The CI gate has never run; "CI green" is documentation-only

- Evidence: `gh api repos/JavaGT/auckland-vpn/actions/runs` → `total_count: 0`
  (no run ever); `gh api .../contents/.github/workflows/tests.yml` → 404 (the
  workflow is not on origin). Locally the gate is real:
  `.github/workflows/tests.yml:1-20` exists and `tests/run-tests.sh`
  (`test_tests_dir_promoted_and_ci_runnable`, pre-fix lines 843-864) greps for
  it — but local main is unpushed (ahead 14 / behind 2, push deferred per #37).
- Why it bites agents: README.md "Testing" ("CI runs exactly that script") and
  AGENTS.md ("CI: GitHub Actions `tests` workflow") present CI as a standing
  backstop; #21 verification check 4 expects "CI green on latest main". No run
  has ever existed, so the check is unverifiable and the sweep could record a
  false green. Runner-specific failures (macos-latest, brew shellcheck) will
  first surface only after #37 lands — gate-fails-late, at the worst time.
- Not fixed here on purpose: the fix path is #37's reconcile-and-push decision.
- Ticket: **#48** (cross-links #37, #20, #21). Reported to #21 in a sweep note.

### F2 (Worth exploring, fixed) — Test suite was all-or-nothing for agents

- Evidence: `tests/run-tests.sh` pre-fix lines 869-895 — 21 hardcoded tests,
  unconditional loop, final summary printed counts only (a failure name
  appeared once, mid-run). Full run timed at ~31s; verifying a one-test change
  cost a full suite run, and a CI/log tail did not show what broke.
- Fix: commit **9d878a0** — optional name-substring arguments select a focused
  subset (`tests/run-tests.sh monitor`, `tests/run-tests.sh config seams`);
  no-match exits 1 with `no tests match any of: ...`; failed test names repeat
  after the final counts. No-argument invocation (the CI contract,
  `test_tests_dir_promoted_and_ci_runnable`) is unchanged.
- Verified: full suite 21/21 green post-fix; `monitor config` selects 5 tests
  in seconds; `zzznope` exits 1 cleanly; `bash -n` clean; shellcheck reports
  only pre-existing warnings in old test bodies (none on new lines).
- Ticket: **#49** (claimed, documents fix SHA).

### F3 (Worth exploring, fixed) — Prior automation findings were unindexed

- Evidence: the 2026-09-10 wave committed reports under `docs/reports/`
  (`2026-09-10-quick-scan.md` in e60cbfb, `2026-09-10-pain-journal.md` in
  0f9550c); the 2026-09-11 wave writes `artifacts/automation-receipts/` and
  `artifacts/reports/`. No AGENTS.md pointer covered any of them — this run
  itself needed the mission brief to learn the locations, and a fresh agent
  re-deriving known findings was the predictable result.
- Fix: commit **96e3a8e** — AGENTS.md "Agent hygiene" now points at
  `docs/reports/` and `artifacts/` (`reports/` + `automation-receipts/`) and
  says to check open `[quick-scan]` / `[config-review]` issues first; the
  Testing section documents the focused-run syntax from F2.
- Ticket: **#50** (claimed, documents fix SHA).

## Checked and found healthy (no action)

- #21 items 1-3 verified green: AGENTS.md carries test/shellcheck/seams/
  pain-journal/consults pointers (landed 960c596); pain journal is live with a
  fresh non-creator 2026-09-11 entry; consult dated addenda in place (ba02a2e).
  Item 4 superseded by F1/#48.
- Session mining: only 3 auckland-vpn sessions exist (all 2026-09-11 review
  verdicts for #38/#39/#40) — no repeated-question or rescue pattern in this
  repo's history; earlier waves' fixes (4e885f6, 51873aa) already addressed
  their findings. No duplicates of #22-#40 re-ticketed.
- Missing-shellcheck UX in the suite (`fail 'shellcheck is required'`,
  run-tests.sh:171) plus the brew command in AGENTS.md/README — adequate.
- Settled decisions preserved: no edits to the config-parser model, privilege
  path, or test seams; AGENTS.md/README split kept (constraints vs behaviour).

## Tickets

| Issue | Severity | State |
|---|---|---|
| [#48](https://github.com/JavaGT/auckland-vpn/issues/48) | Strong | open — fix blocked on #37; follow-up is verifying first CI run |
| [#49](https://github.com/JavaGT/auckland-vpn/issues/49) | Worth exploring | fixed in 9d878a0 |
| [#50](https://github.com/JavaGT/auckland-vpn/issues/50) | Worth exploring | fixed in 96e3a8e |

#21 updated with this run's changes and the #48 caveat for the 2026-09-17
sweep. Cross-links both ways: each issue names this report path; this report
names each issue.

## What I did not look at

- Full session transcripts (metadata only, per mission bounds).
- App code (`auckland-vpn` script internals) — out of scope; covered by the
  quick-scan wave (#22-#35) and #40.
- Sibling lanes of this run: quick-scan and pain-journal children's reports
  and their tickets (#41-#47 range) — not audited here.
- #37 fork-reconciliation content and origin's diverged commits.
- Runner-side CI behaviour (cannot: zero runs exist, see #48).
- Deliberately not changed: `tests.yml` (e.g. a concurrency group) — editing
  an unpushed, never-executed workflow without a runner to validate it would
  repeat exactly the risk #20 tickets.

## Commits

- 9d878a0 tests: focused runs via name-substring args; failed test names repeated in summary
- 96e3a8e AGENTS.md: point agents at prior automation findings and focused test runs
- (this commit) this report.

Focused check at report time: full suite 21/21 green; `git diff --check` clean
per commit. No pushes (origin diverged, #37 open).
