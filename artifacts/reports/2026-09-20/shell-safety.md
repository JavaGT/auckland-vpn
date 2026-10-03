# Shell/YAML static safety scan — 2026-09-20 (read-only discovery)

Scope: `auckland-vpn` (2158 lines), `tests/run-tests.sh` (1027 lines), YAML surface,
`docs/consults/*.md` snippets. NEW hazards only — checked against all 39 open tickets
(`gh issue list`, 2026-09-20) as the anti-list. Every finding below was re-verified at
exact lines with `sed`/`grep` and, where marked, reproduced empirically.

Screen: ShellCheck 0.11.0 (`/opt/homebrew/bin/shellcheck`).
**Main script: rc=0, zero findings, zero `shellcheck` suppress directives in the file**
(verified the tool genuinely parses it — no directives to hide behind). All main-script
findings therefore come from semantics ShellCheck cannot see.

---

## Findings (ranked severity x leverage)

### F1 — MEDIUM (high leverage): doctor's helper-sudoers check passes command+args as ONE argv element; real sudo can never match it

- **Where:** `auckland-vpn:1906` (cmd_doctor)
  ```bash
  elif "$SUDO_BIN" -n -l "$HELPER_BIN start" >/dev/null 2>&1 && "$SUDO_BIN" -n -l "$HELPER_BIN stop" >/dev/null 2>&1; then
  ```
- **Evidence (empirical, this machine):** `sudo -n -l "/bin/echo hi"` →
  `sudo: /bin/echo hi: command not found`, rc=1. Same command as separate operands
  (`sudo -n -l /bin/echo hi`) → rc=0. `sudo -l` takes the command and its args as
  separate operands; an argument with an embedded space is looked up as a literal
  command *name* that cannot exist, so the check **always exits 1**.
- **Consequence:** on every real machine with an installed helper, `doctor` prints
  `FIX  helper installed but sudoers does not allow it — re-run: auckland-vpn setup-sudo`
  and exits 1 even on a perfect install. The OK branch is unreachable under real sudo;
  users are sent into a pointless setup-sudo loop and learn to distrust the one tool
  meant to tell them the truth.
- **Suite masking:** `tests/run-tests.sh:806-869` (`test_doctor_reports_monitor_status`,
  `test_doctor_warns_on_writable_path_entries`) run `cmd_doctor` with the *real* `sudo`
  (no fake) and assert only INFO/WARN lines — the helper FIX/OK branch is never
  asserted, so rc 1 vs 0 is invisible to CI. Same "suite stub masks it" shape as #83.
- **Not covered by (checked):** #71 (doctor PATH-hygiene WARN branch — a different
  check), #43 (monitor helper-missing messaging), #55 (stat/mktemp PATH drift),
  #26 (openconnect version gate), #33 (stale installed build), #29 (pid check).
- **Fix shape:** separate operands: `"$SUDO_BIN" -n -l "$HELPER_BIN" start` (and add a
  test asserting the OK branch under a fake sudo that models real operand parsing).
- **Ticket-ready title:** `[shell-safety] doctor's sudo -n -l check passes "helper start" as one argv element — real sudo can never match it; healthy installs always report FIX`.

### F2 — MEDIUM: `attempt_log | grep -q` falsely fails under pipefail once one attempt's log exceeds the pipe buffer (SIGPIPEs the awk writer)

- **Where:** `auckland-vpn:364` (verify_tunnel_started) and `auckland-vpn:978`
  (cmd_status); minor guarded site `auckland-vpn:343-348` (tunnel_ip_from_log, `|| true`
  already swallows → cosmetic IP loss); propagated site `auckland-vpn:1756`
  (monitor heal verification → "start-unverified").
- **Mechanism:** `attempt_log`'s awk buffers the whole current attempt and writes once
  at END. When that output exceeds the ~64 KiB pipe buffer, `grep -q` exits at the early
  match while awk is still writing → awk dies on EPIPE → rc 141 → `pipefail` makes the
  whole pipeline fail → the `if` branch treats a CONNECTED tunnel as unverified.
- **Repro (3/3 runs):** 117 KB attempt fixture with the match on line 2, run through the
  exact function bodies under `set -euo pipefail` → pipeline rc=141 every time.
- **Consequence:** `start` prints "Connection failed" and dumps the log while the tunnel
  is actually up (and has already marked wanted-up — interacts with #81's doomed-retry
  concern); `status` shows "Connecting..." while connected. This attacks the tool's core
  promise ("start verifies the tunnel").
- **Precondition:** a single attempt's log > 64 KiB. Plausible on retries within
  `--reconnect-timeout=300`; #30's unbounded append-only log is the ambient enabler but
  is a separate lane.
- **Not covered by:** **#83** is the same *class* but a different site and trigger —
  #83 is the `openconnect --help` probe (writer *exits 1*), already fixed pending
  review, and its fix did not touch these two sites (here the writer is *SIGPIPE'd*).
  **#30** is log growth/performance — the precondition, not this correctness hazard.
- **Fix shape:** the #83 fix pattern: capture first, grep the variable —
  `attempt="$(attempt_log)"; grep -qiE ... <<<"$attempt"` (exactly what
  `tunnel_ip_from_log` already does at line 341). One-line change per site.
- **Ticket-ready title:** `[shell-safety] verify_tunnel_started/cmd_status pipe attempt_log into grep -q — under pipefail a >64KB attempt log SIGPIPEs the awk writer and a connected tunnel is reported failed/Connecting`.

### F3 — LOW-MEDIUM: monitor_heal reads the TOTP secret unguarded; a missing/unreadable secret file silently kills the monitor mid-heal

- **Where:** `auckland-vpn:1738` `token="$(read_token_secret)"` under `set -euo pipefail`.
  `read_token_secret` (`auckland-vpn:1116-1118`) is `head -n 1 "$SECRET_FILE" 2>/dev/null
  | tr -d '[:space:]'` — on a missing/unreadable secret file `head` exits 1 → `pipefail`
  → the assignment returns 1 → `set -e` terminates the whole monitor process.
- **Evidence (empirical):** `bash -c 'set -euo pipefail; x="$(head -n 1 /nonexistent
  2>/dev/null | tr -d "[:space:]")"; echo survived'` → exits rc=1 before `echo`.
- **Consequence:** a nohup'd watchdog dies silently — no `monitor_log` entry, no macOS
  notification — mid-heal, leaving the tunnel down with no auto-heal and no trace beyond
  the monitor simply being gone. Trigger: secret file removed/unreadable between start
  and a later heal (user rotation, partial re-setup).
- **Contrast:** cmd_start's twin call (`auckland-vpn:1164`) is gated by
  `[ -s "$SECRET_FILE" ] || die` at 1135. The gate went missing in the duplicated heal
  path — the duplication #24 warns about, but the concrete hazard is not ticketed.
- **Not covered by (checked):** #24 (duplication/drift risk — the cause, not this
  failure), #46 (untested non-dry-run heal branches — adjacent, doesn't name it),
  #43 (helper-missing warn-vs-heal messaging).
- **Fix shape:** gate like cmd_start (`[ -s "$SECRET_FILE" ] || { monitor_log
  "heal=blocked reason=no-totp-file"; notify_user ...; return 1; }`), which also gives
  #46 its missing branch test for free.
- **Ticket-ready title:** `[shell-safety] monitor_heal calls read_token_secret unguarded — missing/unreadable TOTP secret file set -e kills the monitor silently (no log, no notify); cmd_start's twin call is gated`.

---

## Anti-list cross-check (what each relevant ticket covers — none covers F1-F3)

| Ticket | Covers | Relation to my findings |
|---|---|---|
| #83 | --help probe pipefail (writer exit 1), fixed pending review | F2 is the other grep -q sites, different trigger (SIGPIPE) |
| #30 | append-only log growth, whole-file rescans | F2's precondition only; not the branch-flipping hazard |
| #81 | start marks wanted before verified | adjacent to F2's consequence, not F2 |
| #24 / #46 | credential plumbing duplication / untested heal branches | adjacent to F3's cause, not the concrete set -e kill |
| #71 | doctor PATH WARN branch untested, raw $p | not the sudo -l check (F1) |
| #55 | unqualified stat/mktemp PATH drift | same lane as other unqualified calls (id/pgrep), not F1-F3 |
| #29, #47, #53, #74, #75, #80, #43, #44, #22, #23, #26, #78, #79, #35, #20, #48 | as titled | no overlap with F1-F3 |

## Clean areas (verified explicitly)

- **Main script ShellCheck-clean** (0.11.0, rc=0, no suppress directives) — enforced by
  the suite's own static test (`test_static_wrapper`).
- **`ensure_config_dir` write-bit check (line 262) and doctor PATH-hygiene patterns
  (1963-1979) are CORRECT** — near-miss false positive disproven empirically: macOS
  `stat -f '%Lp'` emits octal (`755`, `1777`), so the `[2367]` digit patterns work as
  commented. (The branch being test-less is already #71.)
- `load_config` parse-not-execute property intact (102-137); atomic secret/state writes
  (274-284, 1034-1046, 1368-1384); helper baking uses `%q` for every site value
  (465-476); installer takes all values positionally with zero interpolation (842-895);
  monitor state load validates into locals before committing (1390-1427); bare/unknown
  invocation shows help and exits 2 (2140-2157).
- `[ -z ... ] && return`-style statements throughout are set -e-safe (the test precedes
  `&&`, so its failure never triggers exit).
- **tests/run-tests.sh: no NEW hazards** beyond the #78/#79 lanes. All 14 ShellCheck
  notes triaged as noise: SC2016 at 181 is an intentional single-quoted regex;
  SC2010 `ls | grep` sites operate on controlled sandbox filenames; SC2155
  `export X="$(id -u)"` masks a command that cannot fail; SC2143 at 383 is style.
- **YAML:** `.github/workflows/tests.yml` parses with `python3 -c yaml.safe_load`
  (the `True` top-level key in PyYAML is just YAML 1.1 parsing of `on:`; correct for
  GitHub). Trigger `on: push [main] + pull_request`, `runs-on: macos-latest`,
  checkout@v4, ShellCheck guard, runs `tests/run-tests.sh` — structurally and
  functionally correct. One line on #48: the file **is tracked locally and clean**
  (`git ls-files` shows `.github/workflows/tests.yml`; `git status` empty), so #48's
  gap is origin-side only — no new ticket. Earlier YAML-breakage detection remains
  #20's lane, not re-derived.
- **docs/consults snippets: clean.** All 9 ` ```bash ` blocks (1 in test-architecture.md,
  8 in reliability.md) are quoted, absolute-pathed reference implementations; the audit
  consult uses text/diff blocks only. Nothing copy-paste-unsafe; reliability.md even
  warns against the `sudo -n true` probe pattern.

## What I did not look at

- The **installed** `/opt/homebrew/bin/auckland-vpn` build (#33 says it is stale — I
  reviewed repo source only, so F1-F3 describe the repo, not necessarily the live tool).
- openconnect/gateway runtime behavior, Keychain runtime, real sudoers installs
  (manual-only per README).
- Deep-probe semantics (dig/dscacheutil/scutil) beyond the pipefail lens.
- Log-rescan performance (#30's lane) beyond its role as F2's precondition.
- Git blame/history for when F1-F3 were introduced; remote branch state (#37's lane).
- Monitoring/scheduling automation outside the repo (route policies, LaunchAgents).
