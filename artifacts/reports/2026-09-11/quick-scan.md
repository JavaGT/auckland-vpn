# Quick-scan report — 2026-09-11 (unattended automation run)

Scope: single structured pass over hotspots changed since 2026-08-28
(4e885f6 docs truth-up, 51873aa harness scoring fix, 5cee092/37823a3 test
promotion + monitor). Files walked: `auckland-vpn` (wrapper + generated
helper, sliced), `tests/run-tests.sh`, `.github/workflows/tests.yml`,
README.md, AGENTS.md. Findings deduped against open issues #22-#40 first.

All findings below are ticketed (confirmed vs Speculative/Evaluate as labeled per finding). Ranked by strength x leverage.

## Findings

### 1. [Strong] Stop-path comments promise SIGKILL escalation + guaranteed-gone confirmation the code refuses to provide — #42
- `auckland-vpn:365` claims the helper stop path "escalates to SIGKILL"; the
  helper deliberately refuses SIGKILL (`auckland-vpn:708-716`) and the suite
  asserts the refusal (`tests/run-tests.sh:598`).
- `wait_until_vpn_gone` (`auckland-vpn:366-378`) returns 0 even when the
  process is confirmed still alive, so cmd_restart's "confirm gone"
  (`auckland-vpn:1229-1231`) is best-effort only; `refuse_if_already_running`
  (`auckland-vpn:1109`) is the real backstop.
- Behavior is safe-by-design; the comments contract the opposite and will
  mislead the next maintainer reasoning about wedged-tunnel recovery.

### 2. [Worth exploring] cmd_monitor warns "healing disabled" but monitor_heal still attempts a doomed start — #43
- `auckland-vpn:1760` vs `auckland-vpn:1661-1668` (stop phase skipped when
  helper missing) and `auckland-vpn:1700-1707` (start phase runs anyway,
  notify_user fires "restart failed" each backoff cycle). Narrow trigger
  (intent-up + helper removed under a running monitor), but warning and code
  disagree about who is in charge.

### 3. [Worth exploring] monitor_heal launches without the already-running guard cmd_start enforces — #44
- `refuse_if_already_running` (`auckland-vpn:354-360`) has one call site
  (`auckland-vpn:1109`); observe_state (`auckland-vpn:1494-1499`) trusts only
  the pidfile via `valid_vpn_pid` (`auckland-vpn:1418-1427`), no pgrep
  fallback. A manually-started openconnect beside a dead pidfile record reads
  as `dead` → heal starts a second tunnel → the exact utun/DNS fight the
  guard exists to prevent. Cross-links #29 (pid identity), #22 (breaker).

### 4. [Worth exploring] load_config silently accepts interior whitespace in VPN_USER while its error text says otherwise — #45
- `auckland-vpn:116-118`: the negated bracket class exempts `[:space:]`, so
  `VPN_USER=foo bar` loads without error while the die message claims
  "letters, digits, @ . _ -" only. `cmd_setup` (`auckland-vpn:1011-1014`)
  trims only the ends, so setup can persist such a value. No test covers it.

### 5. [Worth exploring] monitor_heal's non-dry-run branches are untested — #46
- Sole heal test is dry-run (`tests/run-tests.sh:715`); monitor_heal returns
  at `auckland-vpn:1649-1653` before any real logic. Untested: network gate
  (`1636-1641`), five credential-block branches (`1672-1698`), sudo error
  classification (`1701-1707`), unverified start (`1716-1718`). The
  `AUCKLAND_VPN_SUDO_BIN`/`AUCKLAND_VPN_HELPER_BIN` seams (`148-167`) were
  built for exactly this. Cross-links #23, #28 (stop-side paths).

### 6. [Speculative — Evaluate] installer's uid/gid numeric check concatenates the values — #47
- `auckland-vpn:815-817`: `case "$CALLER_UID$CALLER_GID"` — `""`+`"0"` passes
  the gate. Unreachable today (wrapper validates each, `auckland-vpn:873-876`).
  Implementation explicitly NOT the todo; evaluate whether two lines of
  defense-in-depth in a root-run script are worth it.

## Non-findings worth recording

- 51873aa harness fix is sound: marker file crosses the subshell boundary and
  is cleared per test (`tests/run-tests.sh:14-21, 852-862`); no residual
  false-green hole spotted.
- `.github/workflows/tests.yml` is minimal and consistent with the manual-only
  privileged/live claims (#20 already tracks YAML-breakage detection).
- `set -euo pipefail` (`auckland-vpn:22`) makes cmd_restart abort on a failed
  cmd_stop — the "second tunnel beside a dying one" hazard is guarded for the
  wrapper path; the comment fixes in #42 close the documentation gap.
- setup-sudo flow (staging in STATE_DIR, visudo -cf before install, positional
  parameters into install.sh, NOSETENV) held up under review; only #47's nit.

## Tickets

New: #42 (Strong), #43, #44, #45, #46 (Worth exploring), #47 (Evaluate).
Existing cross-linked, no new evidence: #22, #23, #28, #29 (referenced from
#44/#46 bodies where relevant).

## What I did not look at

- docs/consults/*.md bodies beyond what commits referenced; the Keychain
  security invocation surface (stored_vpn_password / setup's Keychain write,
  lines ~1023-1065); macOS-version sensitivity of `stat -f`/`mktemp` calls;
  origin-divergence reconciliation (#37); prototype code under prototypes/;
  CI runner behaviour beyond reading the 20-line workflow.
