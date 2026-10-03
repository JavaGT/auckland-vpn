# Config review — auckland-vpn (2026-09-14 0930 wave)

## Scope and method

Read-only review of agent workflow configuration and recent automation evidence. I ran `opencode2 api get /api/session` (titles/status metadata only), inspected the requested repo/user config files and hook candidates, read issues #21, #54, #57, and #58, and sampled the 2026-09-13 and 2026-09-14 automation receipts. No app code, config, or tracker issue was edited. The only write was this report.

## Ranked findings

### 1. Strong — stale inline route policy costs a re-verification on every sampled run (known #54)

**Evidence:**

- `artifacts/automation-receipts/2026-09-13/unsupplied-20260913T0930-attempt-1-auckland-vpn-0930.md:17-18` says the inline policy was stale and had to be re-verified against `MODEL-ROUTING.md`.
- `artifacts/automation-receipts/2026-09-13/unsupplied-20260913T1000-attempt-1-auckland-vpn-1000.md:18-20` records the same stale-policy re-verification.
- `artifacts/automation-receipts/2026-09-14/unsupplied-20260914T0930-attempt-1-auckland-vpn-0930.md:8-10` records the 2026-09-13T02:08:05Z policy as expired at dispatch and repeats the route check.

**Measured recurrence:** 3 of 3 sampled runs (100%) paid the reconciliation cost; at least one route check per run. This is not a hypothetical drift: the policy expires after 24 hours while scheduled waves recur daily.

**Proposed change:** make the scheduler regenerate `verified_at` for every wave, or replace the absolute freshness gate with an explicit instruction to re-verify against `/Users/server/.config/opencode/MODEL-ROUTING.md` when stale. Keep #54 as the decision ticket; do not duplicate it.

### 2. Worth exploring — the due-date verification ticket cannot currently prove CI is green using the documented workflow lookup

**Evidence:**

- Issue #21 requires “CI `tests` workflow green on latest main” (`gh -R JavaGT/auckland-vpn issue #21`).
- `.github/workflows/tests.yml:5-20` clearly defines a workflow named `tests` and its full-suite command.
- `gh -R JavaGT/auckland-vpn run list --workflow tests` returned `could not find any workflows named tests`; an unfiltered `run list` returned no runs in the available result set. Thus the requested item is not verified, even though the workflow file exists.

**Proposed change:** add a small, documented verification command that resolves the workflow by repository file or workflow ID, reports “no runs found” distinctly from “green,” and records the latest main SHA. Do not mark #21 complete from the workflow file alone. This is verification friction, not an application defect.

### 3. Worth exploring — the scheduler’s “no supplied run ID” fallback is repeated and weakens receipt traceability

**Evidence:**

- `artifacts/automation-receipts/2026-09-13/unsupplied-20260913T0930-attempt-1-auckland-vpn-0930.md:7-8` says the scheduler supplied no ID and the run ID was inferred.
- `artifacts/automation-receipts/2026-09-13/unsupplied-20260913T1000-attempt-1-auckland-vpn-1000.md:7-8` repeats this.
- `artifacts/automation-receipts/2026-09-14/unsupplied-20260914T0930-attempt-1-auckland-vpn-0930.md:4,8` repeats it again, with `finished_at` still `pending` at inspection time.

**Proposed change:** have the scheduler always inject a run ID and attempt number; make the receipt schema reject or explicitly classify a missing ID rather than silently adopting a convention. If the scheduler cannot do that, document the fallback as a first-class stable contract and add a completion update for pending receipts.

### 4. Speculative — route/config duplication remains a future drift risk, although no contradiction was confirmed today

**Evidence:**

- `/Users/server/.config/opencode/MODEL-ROUTING.md:28-43` is a hand-maintained route table.
- `/Users/server/.config/opencode/opencode.json:7-269` separately defines agent IDs, models, modes, and permissions.
- `/Users/server/.zcode/AGENTS.md:124-129` tells agents to use the routing document, while `/Users/server/.config/opencode/MODEL-ROUTING.md:13-23` repeats CLI model-selection rules.
- The current API sample contained only this repo session, `ses_f634fa98affeWWxqQ0GIa55aWO`, titled “Read-Only Agent Config Review and Friction Report”; it showed no conflicting route outcome. The 2026-09-13 receipts likewise reported successful route checks.

**Proposed change:** derive a machine-readable route check from `opencode.json` and compare it with `MODEL-ROUTING.md` in a concise diagnostic command or scheduled preflight. Keep the human table as policy, but flag missing/disabled agent IDs and model mismatches automatically.

## Known findings deliberately not re-derived

- **#54:** stale inline route policy; quantified above from three receipts.
- **#57:** ZCode-only `===` guard coverage gap. `/Users/server/.zcode/hooks/bash-guard.mjs:2-5` identifies a Bash-tool-only hook, while `AGENTS.md:50-52` documents the gap. The sampled 2026-09-13 receipt says the issue was already ticketed and the current session sample showed no new rescue/failure signal.
- **#58:** split report trees. `AGENTS.md:40-43` points agents to both locations; the split is already tracked for evaluation.

## #21 verification snapshot (due 2026-09-17)

1. **Repo guidance:** verified. `AGENTS.md:22-31` documents tests, ShellCheck, wrapper-only seams, and consult locations; `AGENTS.md:33-43` documents the pain journal and report pointers.
2. **Live pain-journal pointer:** partially verified. `/Users/server/.config/opencode/pain-journals/auckland-vpn.md:3-11` exists and records mined entries and their ticket mappings. Git history for this external file was unavailable because it is outside this checkout, so I could not prove authorship by a non-creator.
3. **Consult truth-up:** verified for the inspected consults. `docs/consults/reliability.md:3-17` has dated 2026-09-10 and 2026-09-13 status addenda; `docs/consults/test-architecture.md:3-5` states the suite moved from `prototypes/tests/` to `tests/run-tests.sh` and calls old paths historical. No sampled recent report treated those as current implementation paths.
4. **CI green:** not verified. `.github/workflows/tests.yml` exists, but the GitHub CLI workflow query returned “could not find any workflows named tests,” and no unfiltered run result was available. Leave this item open.

## Session-friction evidence

The API returned one repo-local session in the available page: `ses_f634fa98affeWWxqQ0GIa55aWO` (current review, no outcome field yet). It did not expose summaries/transcripts, and I did not read any transcript. Recent receipts report session mining with no additional auckland-vpn friction: 2026-09-13 0930 (`...0930...md:18`) found two completed review sessions; 1000 (`...1000...md:18`) found no new friction since 0930. I found no evidence in the sampled metadata of a rescue follow-up, stalled child, or late gate failure. The repeated operational friction that is evidenced is the stale route recheck above.

## What I did not look at

- No session transcripts, message bodies, or secrets.
- No application implementation or privileged VPN behavior.
- No full historical OpenCode pagination beyond the API page returned by `opencode2 api get /api/session`; therefore the session sample is bounded, not a complete three-day census.
- No live OpenCode/ZCode hook execution, scheduler source, or external CI dashboard beyond the read-only GitHub CLI queries.
- No changes to `AGENTS.md`, user config, hooks, issues, or commits.
