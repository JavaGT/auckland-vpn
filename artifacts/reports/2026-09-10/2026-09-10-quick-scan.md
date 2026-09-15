# Quick-scan playbook report — auckland-vpn (2026-09-10)

Unattended quick scan over the post-build-burst hotspots (all hotspots date from
the 2026-08-23/24 burst, commits a9aa67e..5cb68ef). Read order honored:
AGENTS.md → docs/consults/{openconnect-audit,reliability,test-architecture}.md →
`auckland-vpn` (all 2035 lines), `tests/run-tests.sh`, `.github/workflows/tests.yml`,
`README.md`.

**Baseline:** `bash tests/run-tests.sh` → **21 passed, 0 failed** (exit 0).

**Tracker:** every finding below is filed against `gh -R JavaGT/auckland-vpn`
(deduped against open issues; only #1 was open, unrelated). No implementation was
performed; no tickets closed.

## Ranked findings

Ranked by strength × leverage. Severity per finding; issue number cross-linked.

### 1. [Strong] Circuit breaker never half-opens — cooldown expires into an immediate re-open without a heal attempt → **#22**

`auckland-vpn:1611-1617` opens the circuit when `restart_attempts > MAX_RESTART_ATTEMPTS`
and nothing resets the counter at cooldown expiry; `auckland-vpn:1544-1547`
short-circuits every poll while `circuit_until` is in the future. Counters only
reset via healthy-x2 (`auckland-vpn:1533-1536`) or manual `start`
(`auckland-vpn:1384-1390`), both unreachable while a tunnel stays down. After
~20 min of failed backoff the monitor re-opens the breaker every hour, forever,
without ever attempting the heal the whole feature exists for.
`docs/consults/reliability.md` §Backoff explicitly specifies a half-open attempt.
Smallest fix: on expiry with the tunnel still bad, set
`restart_attempts = MAX_RESTART_ATTEMPTS` so exactly one attempt occurs before a
re-open.

### 2. [Strong, operational] Installed wrapper AND privileged helper are stale pre-hardening builds → **#33**

`cmp /opt/homebrew/bin/auckland-vpn` vs repo: DIFFERS (1386 diff lines). The
installed copy uses the old `LOG_FILE="$STATE_DIR/auckland-vpn.log"` layout and
has no test seams — it predates the entire burst. The installed
`/private/etc/auckland-vpn/helper` (root:wheel, Sep 7) contains **no
`--non-inter`** and bakes the old log path — so the deployed root-side surface
also predates the hardening. Since AGENTS.md names `/opt/homebrew/bin/auckland-vpn`
as the deployment, none of the burst's fixes are live on this machine. Fix is the
documented redeploy: copy + re-run `setup-sudo` (one sudo prompt, owner action;
privilege path → hostile review per AGENTS.md). Evidence appended to #33 as a
comment.

### 3. [Worth exploring] Helper stop-refused never enters the circuit breaker; real heal outcomes untested → **#23**

`monitor_heal` returns 3 on stop-refused (`auckland-vpn:1659-1666`) but
`monitor_act`/`cmd_monitor` merely log `act=failed` (`auckland-vpn:1781-1787`);
the consult requires the breaker on this trigger. The only monitor-heal test is
dry-run, which returns before the stop phase (`auckland-vpn:1647-1651`), so rc 1
and rc 3 have zero coverage.

### 4. [Worth exploring] Credential plumbing duplicated between `cmd_start` and `monitor_heal` → **#24**

Keychain→file fallback + newline rejection written twice
(`auckland-vpn:1090-1102` vs `auckland-vpn:1669-1696`) despite the consult's
"same credential plumbing" contract and the existing shared `try_helper_start_n`
(`auckland-vpn:1079-1081`). Drift here makes start and auto-heal diverge.
Smallest fix: extract `resolve_stored_password()`.

### 5. [Worth exploring] Trust-store docs contradict the audit → **#25**

README (`README.md:23-25`, `README.md:94-99`) and the script header
(`auckland-vpn:13-15`) say trust comes from "the system's / Mac's built-in CAs";
the audit (§4, CONFIRMED) established this install trusts the Homebrew GnuTLS
Mozilla store, not the macOS Keychain, and prescribed replacement wording — never
applied. Docs-only fix; does not reopen the no-pinning decision.

### 6. [Worth exploring] No OpenConnect version/capability gate beyond `--pid-file` → **#26**

Only `openconnect_supports_pid_file` (`auckland-vpn:210-213`) probes features;
audit §7 recommends >= 9.21 plus `--protocol/--token-mode/--token-secret/--non-inter`
checks (v8 builds with `--pid-file` but no Fortinet exist). Extend the existing
`--help` grep pattern in the `setup-sudo` prereq gate.

### 7. [Worth exploring] Ctrl-D at interactive prompts exits silently → **#27**

`read -r RAW` (`auckland-vpn:976`) and `read -rs -p PASS` (`auckland-vpn:1021`)
lack the `|| true` the username read got explicitly (`auckland-vpn:1009`), so EOF
under `set -e` bypasses the friendly "aborted." dies. Two-line consistency fix.

### 8. [Worth exploring] Helper's stale/reused-PID stop path untested → **#28**

The "recorded pid is no longer our openconnect" branch (`auckland-vpn:689-696`)
is the only untested branch of helper `cmd_stop`; the test-architecture consult
lists PID-reuse fixtures as "promote next" (`docs/consults/test-architecture.md:220`).
One integration test with a dead/foreign PID in the pidfile closes it.

### 9. [Worth exploring] `running_vpn_pid` identity check weaker than its siblings → **#29**

Pidfile branch accepts ANY openconnect (`auckland-vpn:270-274`) while helper stop
(`auckland-vpn:692-693`) and `valid_vpn_pid` (`auckland-vpn:1416-1425`) require
openconnect AND `$SERVER`. Wrapper can claim connected for a foreign tunnel the
helper would refuse. Align on one predicate.

### 10. [Worth exploring] Append-only VPN log grows unboundedly; hot paths rescan it → **#30**

`attempt_log` awk reads the whole file per call (`auckland-vpn:293-295`), polled
every 0.5 s during start-verify and every 20 s monitor observation
(`auckland-vpn:1502`); no rotation exists ("keeps growing", `README.md:111-117`).
The no-chown rationale only binds root — the log is user-owned, so wrapper-side
rotate-at-start (mv to `.old`, mirroring `monitor_log`'s 256 KiB pattern at
`auckland-vpn:1394-1399`) needs no privilege change.

### 11. [Speculative — Evaluate] Enforce fixed-literal notification text → **#31**

`notify_user` string-interpolates into AppleScript source
(`auckland-vpn:1406-1411`); all ten call sites currently pass fixed literals, but
nothing enforces the consult's rule. Evaluate a grep lint or argv-passing.
Implementation NOT the todo.

### 12. [Speculative — Evaluate] Audit's verbose foreground diagnostic mode → **#32**

Audit §6's one-attempt `-v --timestamp` capture with private raw log + redacted
report was never built nor explicitly rejected; shipped `cmd_diagnose` is
deliberately read-only (`auckland-vpn:1917-1931`). Decide whether the shareable
diagnostic capability is wanted. Implementation NOT the todo.

## Checked clean (no issue warranted)

- **CI workflow does not duplicate local test logic** — `.github/workflows/tests.yml`
  is a thin wrapper (checkout, shellcheck ensure, run `tests/run-tests.sh`); the
  suite itself asserts the workflow stays macOS + this script
  (`test_tests_dir_promoted_and_ci_runnable`).
- **`--non-inter` handling** — correctly fixed-argv in the generated helper
  (`auckland-vpn:647`), asserted in contract + integration tests. (The wrapper has
  no user-facing `--non-interactive` flag; nothing to handle.)
- **`sudo -n` liveness** — no `sudo -n true` anywhere; `doctor`'s
  `sudo -n -l <exact cmd>` policy check is the consult-approved form.
- **Config parsed-never-executed** — intact and tested (rejection of shell code,
  conflicting users, unbalanced quotes, bad chars).
- **Lock/pidfile/signal lifecycle** — helper operation lock (empty-marker grace,
  dead-holder takeover, rmdir-only), monitor lock, EXIT-mapped signal traps, and
  no-SIGKILL stop timeout are all implemented and covered by dedicated tests.
- **Quoting** — installer is fully positional-parameter based and tested against
  adversarial paths; helper bakes values with `%q`.
- **README vs code spot-checks** — monitor knobs/filenames, verify timing (~15 s),
  stop timeouts (~10 s), bare-invocation exit 2, uninstall steps, reconnect-wording
  fix from audit P1 all match the implementation.
- **Backoff cap 15 min vs consult 10 min** — deliberate; superseded in-code with a
  comment (`auckland-vpn:1519-1520`). Not re-litigated.

## What I did not look at

- Real privileged behavior: actual `visudo`/sudoers authorization, root ownership
  transitions, real Keychain prompts, live VPN/DNS/routes — manual-only per the
  test-architecture consult; CI and this scan run unprivileged.
- `vpnc-script` internals and OpenConnect upstream behavior — covered by the
  2026-08-23 audit; not re-derived.
- Open issue #1 ("Consider exploring openfortivpn performance") beyond title-level
  dedupe — unrelated to all findings above.
- Deeper monitor heuristics (DNS probe cadence every 20 s vs the consult's 60 s
  split, flap-loop detection from the consult's second breaker trigger) — noted as
  consult/code drift inside #22/#23 scope but not separately audited.
- Installed-vs-repo drift for anything besides the wrapper script and helper
  (e.g. sudoers fragment content — not readable unprivileged).
