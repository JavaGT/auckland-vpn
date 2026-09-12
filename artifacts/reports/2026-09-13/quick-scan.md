# quick-scan report — 2026-09-13 0930 wave

Scope: the twice-carried blind spot from the 09-10/09-11/09-12 reports —
`docs/consults/reliability.md` body (claims not owned by open tickets) and
`docs/consults/test-architecture.md` body — plus a README↔code command-surface
sweep. All 26 open issues at start were treated as settled; nothing re-derived.

## Findings

- **#56 (new, evaluate-framed)** — The consult's breaker spec
  (`reliability.md:366-371`) has two triggers the shipped breaker does not
  implement: the windowed "5 attempts within 30 minutes" rule (code counts
  cumulatively, `auckland-vpn:1271`, `:1614-1618`) and the flap-loop trigger
  (no flap logic exists). The 09-10 report (`docs/reports/2026-09-10-quick-scan.md:152-155`)
  scoped both "inside #22/#23" but neither body mentions them (checked via
  `gh issue view`) — the disposition pointer led nowhere on the tracker. The
  backoff-cap facet (15 vs 10 min) was judged deliberate on 09-10 and is
  excluded. Doc truth-up applied: status addenda added to `reliability.md`
  (same pattern as the 2026-09-10 addendum from #19).

## Claimed-shipped facts verified clean (no drift)

Consult status headers vs code, all confirmed at exact lines:

- `monitor-state` filename `auckland-vpn:174`; intent wiring `start` sets /
  `stop` clears (`:1118`, `:1177`) — matches consult §operating model.
- Foreground-only monitor: no launchd/LaunchAgent code anywhere.
- `monitor.log` ~256 KiB rotation (`:1399-1402`); atomic never-sourced state
  (`:1326-1350`); notification fixed-literal convention (`:1407-1415`, #31
  owns the enforcement ticket).
- Heal path prohibitions hold: `monitor_heal` (`:1653+`) has its own start
  phase — never falls back to an interactive sudo prompt (password-required →
  blocked + notify), never pattern-kills, never deletes pidfiles.
- `cmd_start` grant check classifies stderr instead of `sudo -n true`
  (`:1129-1147`) — matches consult §security boundary and AGENTS.md.
- README↔code: all 10 documented commands exist in the dispatch
  (`:2028-2038`); the undocumented-looking `pin` is documented at README:106.
- `tests/run-tests.sh` ShellChecks both wrapper (`:174`) and generated helper
  (`:191`, `:556`); wrapper direct-execution guard exists (`auckland-vpn:747`)
  — matches test-architecture consult.

## Blind spots closed this wave

- `prototypes/` carried blind spot: moot — directory does not exist (promoted
  in 5cee092/37823a3); the suite tripwire (`tests/run-tests.sh:841`) guards it.
- `docs/consults/reliability.md` and `docs/consults/test-architecture.md`
  bodies: walked; drift found is ticketed as #56 above.

## What I did not look at

- Real privileged behavior (visudo, ownership transitions, live VPN) —
  manual-only per the test-architecture consult; this run is unattended.
- #37 origin-divergence reconciliation and #48 CI activation — owner-gated.
- #21 follow-up (verify friction fixes landed) — due 2026-09-17, not run early
  (prior waves' explicit decision, respected).
- Monitor heal non-dry-run branch coverage — #46 owns it.
- macOS-version sensitivity of `stat -f`/`mktemp` — #55 owns it.
- Session-mining side of config-review: both auckland-vpn opencode sessions in
  the store are completed review runs (no stalls/rescues) — no friction signal
  to mine; recorded in the wave receipt, not a separate report.
