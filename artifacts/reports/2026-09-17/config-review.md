# config-review — 2026-09-17 0930 wave (discovery child, read-only)

Scope mined: repo AGENTS.md + README.md claims vs script/tests reality;
outside-repo agent config (~/.zcode/AGENTS.md, opencode.json, MODEL-ROUTING.md,
pain journal, recover-frozen-session skill, shared route policy, LaunchAgents);
wave receipts 2026-09-15/16/17; docs/consults/*.md. No issues filed, no git
mutations (unattended run). Known-ticketed findings NOT re-derived: #66 (stale
deepseek-hosted-flash binding), #54 (stale inline route policy re-verified per
run), #57/#68 (bash-guard ZCode-only), #67 (scheduler misfires), #60 (no
run_id), #33 (stale installed binary — confirmed still DIFFERS, cmp), #48
(tests.yml absent on origin).

## Findings (ranked)

### F1 — Strong: pending one-shot LaunchAgent fires today 10:00 for completed work, and its dispatch is broken three ways

At report time (09:41+12:00) `com.opencode.auckland-vpn-followup-20260917` is
loaded and armed to fire at 10:00 today
(`~/Library/LaunchAgents/com.opencode.auckland-vpn-followup-20260917.plist`,
StartCalendarInterval 2026-09-17 10:00; `launchctl list` shows it loaded, no
log at ~/Library/Logs/auckland-vpn-followup-20260917.log yet). Its script
`~/.config/opencode/auckland-vpn-followup-20260917.sh` re-verifies #21, then
comments on and closes it. All three embedded assumptions are stale:

1. **Issue already closed.** #21 is CLOSED (closed out-of-band 2026-09-16 by
   the 0930 wave's own #21 verification — receipt
   artifacts/automation-receipts/2026-09-16/unsupplied-20260916T0930-attempt-1-auckland-vpn-0930.md:
   "config-review: #21 verification run (checks 1-3 pass, check 4 blocked by
   #48/#37) — closed"). The job will comment on a closed issue and attempt a
   redundant close.
2. **Agent id no longer exists.** Script line 9 dispatches
   `opencode2 run --agent implement --model openai/gpt-5.6-luna`. No
   `implement` agent exists today (live opencode2 agent list, opencode.json,
   ~/.config/opencode/agents/ all checked) — the 2026-09-10-era id was
   removed/renamed (grunt lane is now `grunt-alpha` / `openai-gpt-5.6-luna`).
3. **Test count stale.** Script says "bash tests/run-tests.sh passes (21
   expected)"; the suite is now 25 tests (tests/run-tests.sh `tests=(` array;
   25/25 logs from 2026-09-16). The script is a one-shot that "self-unloads"
   only on success of firing — it never reconciles against tracker state.

Same class, already evidenced as residue: failed one-shot
`~/.config/opencode/scheduled/scope-config-merge-after-settle.status`
(`finished=2026-09-08T23:34:24Z exit_code=1`, script + plist left in place 9
days later).

**Root config gap:** scheduled one-shot follow-ups have no reconciliation
step — closing the ticket early leaves the LaunchAgent armed, and the script
never checks issue state before dispatching.

**Proposed fix:**
- Immediate remediation (coordinator, before 10:00; outside this child's
  write scope): `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.opencode.auckland-vpn-followup-20260917.plist && rm <plist>` (and the stale
  script in ~/.config/opencode/).
- Direct-edit candidate (AGENTS.md agent-hygiene bullet): "When a wave closes
  an issue that has a pending scheduled follow-up, boot out and remove its
  LaunchAgent; one-shot follow-up scripts must no-op when the tracker issue is
  already closed."
- Evaluate-ticket: one-shot scheduled scripts should start with a
  `gh issue view <n> --json state` guard and self-unload on failure too
  (mirrors the scope-config-merge residue).

### F2 — Strong: the designated rescue tool hard-fails whenever the shared route policy is stale, and nothing refreshes it

recover-frozen-session consumes `~/.zcode/automations-redesign/route-policy.json`
(default per recover-frozen-session.mjs:131). Every route carries
`verified_at: 2026-09-13T02:08:05Z`, `stale_after_seconds: 86400` — stale
since 2026-09-14 02:08Z; `policy_version "2026-09-13.2"` is the same policy
waves have been re-verifying inline (#54). The loader hard-throws on staleness
(`~/.zcode/skills/recover-frozen-session/scripts/route-policy.mjs:53-54`,
"route verification is stale"), the helper surfaces it as route-policy-invalid
(recover-frozen-session.mjs:641,669), and the SKILL.md forbids working around
it ("never invent or bypass one", lines 30/71). Net effect: the tool whose job
is rescuing stalled sessions refuses to run precisely when automation stalls,
unless someone first refreshes the policy. Live confirmation — pain journal
`~/.config/opencode/pain-journals/auckland-vpn.md`, unmined 2026-09-17 line:
"Union Alpha provider ended unexpectedly; recovery helper was blocked by the
stale shared route policy."

**Relation to #54:** same root cause (daily-freshness gate over a stable
table), different consequence — #54 tracks the per-run re-verification cost of
the inline copy; this is the rescue path refusing outright. Not previously
ticketed for the rescue path; the 2026-09-17 journal line is unmined.

**Proposed fix (evaluate-ticket, plus one mechanical step):**
- Mechanical/direct: re-verify the routes against
  ~/.config/opencode/MODEL-ROUTING.md:32-44 (they still match: rows 33/37/41 =
  agents/deepseek-v4.1-flash.md + grunt-alpha.md frontmatter) and refresh
  verified_at / bump policy_version — restores the rescue path today.
- Structural: add a config-review playbook step — "if route-policy.json is
  past stale_after, re-verify against MODEL-ROUTING.md and refresh it" — or
  change route-policy.mjs to accept a live re-verification attestation instead
  of a hard throw (skill change; owner decision). Fold the 2026-09-17 journal
  line into whichever ticket carries it.

### F3 — Worth-exploring (direct-edit): AGENTS.md artifact navigation omits artifacts/reviews/

AGENTS.md:40-42 tells agents prior findings live under
`artifacts/reports/<date>/` plus `artifacts/automation-receipts/` — but
hostile-review verdicts land in `artifacts/reviews/` (exists,
2026-09-15-0930-45-hostile.md, 2026-09-15-1000-63-hostile.md; cited as
evidence by the 2026-09-15 receipts). An agent following AGENTS.md navigation
misses prior review verdicts. Fix: one-line AGENTS.md edit adding
`artifacts/reviews/`.

### F4 — Speculative: MODEL-ROUTING.md route table duplicates a route

MODEL-ROUTING.md rows 33 and 37 are the same `--agent deepseek-v4.1-flash` +
`--model deepseek/deepseek-flash` pair under two role labels ("Hostile
review" and "DeepSeek v4.1 Flash (DeepSeek-hosted direct)"). Both currently
resolve (agents/deepseek-v4.1-flash.md frontmatter matches), so this is
confusion risk, not breakage. Likely folds into #66's derived
opencode.json<->MODEL-ROUTING consistency check — noted here only so the
derived check's spec can name row-dedup explicitly.

## Verified clean (claims that hold)

- README command/flag list matches the script exactly: dispatch case
  auckland-vpn:2137-2149 (setup, setup-sudo, start, stop, restart, status,
  monitor, log, pin, doctor, diagnose, help; bare/unknown -> usage, exit 2),
  usage text auckland-vpn:2102-2133; `log -f` (:999), `monitor --once`
  (:1786-1787), `--reconnect-timeout=300` (:684); all 12 monitor env knobs
  present; second `usage()` at :509 belongs to the generated helper
  ("auckland-vpn helper" die prefix), not a drift.
- README paths match script constants: vpn.pid (:156), log dir (:157),
  monitor-state/lock/log (:185-187) = README.md:124-144,231-233 and
  docs/consults/reliability.md:5,60-61.
- AGENTS.md testing claims match tests/run-tests.sh: substring filter
  (`monitor`) works (:984-1000), no-args = full suite, shellcheck required
  (:172), seams AUCKLAND_VPN_HELPER_BIN/AUCKLAND_VPN_SUDO_BIN honoured and
  tested (:885-902) and present in the wrapper.
- docs/consults/test-architecture.md seam references (:101-106, :126) match
  the shipped seams; `prototypes/` mentions (:10,:193,:239) are dated-design
  history under a 2026-09-10 status addendum (:3) — no live misdirection.
- `docs/reports/` mentions repo-wide are historical only (AGENTS.md:42
  documents the #58 move; receipts quote old logs). No live reference to a
  moved path outside history.
- AGENTS.md:43 `[quick-scan]`/`[config-review]` tracker prefixes: both live
  in the open-issue list (e.g. #56, #68, #67, #66, #60, #54).
- ~/.zcode/AGENTS.md pointers (pain journal path, MODEL-ROUTING.md,
  recover-frozen-session skill) all resolve.

## Wave-receipt coverage notes (2026-09-15/16/17)

- Repeated classes are the known ones: unsupplied run_id on every receipt
  (#60), double/early slot fires on 09-16 — 4 receipts across 2 slots (#67),
  stale inline policy re-verified every dispatch (#54). No new failure class
  in receipts.
- No stalled playbook: quick-scan was correctly skipped on an unchanged
  frontier (09-16 1000 attempt 2 admission); pain-journal is receipt-only
  ambient by design; hostile-review lane produced artifacts/reviews/ verdicts
  on 09-15. The only genuine stall evidence is F2's blocked recovery (pain
  journal 2026-09-17).
- Stale-artifact residue: `~/.config/opencode/auckland-vpn-followup-20260917.sh`
  + plist (F1) and the failed scope one-shot (F1 supporting) are the only
  unreconciled scheduled items found.
