## Findings

Reviewed the complete script, suite, README, AGENTS, consults, September 19–20 reports, prior reviews, and all 58 open issues. No files edited. Syntax checks and wrapper ShellCheck passed; the suite was not executed because it writes fixtures inside the repository. Git status remained unchanged.

All findings below are source-confirmed unless marked **NEEDS-LOG**. Existing issue numbers identify tracked work, not new discoveries.

### (a) Security hardening

| ID | Severity | File:line | What is wrong | Concrete fix desire | Existing seams? |
|---|---|---|---|---|---|
| S1 | high | `auckland-vpn:583–591` | The helper’s trust walk follows a symlink target and abandons the link’s original ancestors. A writable directory containing the link can escape validation. #85 | Validate both the original ancestor chain and every resolved target chain, including intermediate links; retain bounded cycle detection. Apply the same correction to doctor’s walk. | Yes: generate an unchanged helper against adversarial fixture paths. Root ownership remains manual-only. |
| S2 | high, conditional | `auckland-vpn:930–933`, `:947` | `setup-sudo` persists the wrapper’s environment-selected helper path into sudoers. If that path has a user-writable parent, the installed root-owned helper can subsequently be replaced. #75 | Production `setup-sudo` must refuse noncanonical helper destinations before sudo. Keep lifecycle seams available for tests; test setup by sourcing and sandbox assignment. | Yes: fake sudo must record zero calls on refusal. |
| S3 | medium | `auckland-vpn:1076` | Keychain setup exposes the password in `security`’s argv. #53 | Use a verified non-argv Keychain input mechanism, with explicit escaping and no diagnostic echo of its input. Do not adopt `security -i` without testing its parser and output behavior. | Yes for argv/input assertions; actual Keychain behavior needs a manual test. |

**Details:** S1 affects a root-executed binary validation boundary, not merely doctor’s advisory output. S2 requires an overridden installation destination; the normal destination is protected. Both fixes require hostile privilege-path review. Neither requires broader sudo rights.

### (b) Shell-safety / robustness

| ID | Severity | File:line | What is wrong | Concrete fix desire | Existing seams? |
|---|---|---|---|---|---|
| R1 | medium | `auckland-vpn:364`, `:978` | `attempt_log \| grep -q` can SIGPIPE the producer, making connected evidence fail under `pipefail`. #90 | Capture the attempt first and search it without an early-closing producer pipeline, or use a consumer that drains its input. Preserve read-error handling. | Yes: large attempt-log fixture. |
| R2 | low | `auckland-vpn:1019–1020`, `:1067` | EOF bypasses the intended “aborted” errors. Secret normalization also interprets pathological input such as `-n` as echo options. #27/#80 | Handle failed reads explicitly; replace variable-data `echo` with `printf '%s\n'`. Retain `read -rs`, which already includes `-r`. | Yes: fresh subprocesses with closed stdin and literal-input fixtures. |
| R3 | medium | `auckland-vpn:1326–1328`, `:1659` | Digit-only validation accepts values that Bash arithmetic cannot safely consume. `CIRCUIT_COOLDOWN=08` passes validation and later errors as invalid octal. Persisted counters share the problem. | Normalize bounded decimal integers before arithmetic, or reject noncanonical representations. Reject overflow; require a positive polling interval. | Yes: sourced validation/state fixtures. |
| R4 | medium | `auckland-vpn:255–257`, `:1442` | Unqualified BSD `stat` can resolve to GNU `stat`; credential-directory checks fail and monitor rotation silently sees size zero. #55 | Use `/usr/bin/stat` and `/usr/bin/mktemp` consistently for platform-specific operations. | Yes: PATH-shadow fixtures and static assertions. |

**Details:** R1 reproduced with an in-memory large attempt: pipeline status **141**. This is a false branch result, even though the pipeline occurs inside `if`; conditional placement prevents shell termination, not SIGPIPE-induced misclassification.

### (c) Behaviour / UX contracts

| ID | Severity | File:line | What is wrong | Concrete fix desire | Existing seams? |
|---|---|---|---|---|---|
| B1 | medium | `auckland-vpn:1906–1909` | Doctor passes `"helper start"` as one command operand to `sudo -l`, producing a false FIX. Also, permission listing alone does not establish passwordless execution. #89 | Pass helper and action separately. Report command authorization accurately; claim NOPASSWD only when that policy property is established. | Yes: argument-sensitive fake sudo. |
| B2 | medium | `auckland-vpn:295`, `:363–364`, `:978` | Wrapper identity accepts any `openconnect`; startup verification accepts any nonempty PID file plus historical connection text, without checking a live owned process. #29 | Require the fixed server identity for recorded PIDs; require a live matching PID before startup success. Status must not label a reconnecting process connected solely from an earlier marker. | Yes: process/log fixtures. |
| B3 | medium | `auckland-vpn:619`, `:644–647` | The helper lock serializes operations but does not prevent sequential duplicate starts. Two wrappers can both pass their preflight before the first tunnel starts; the second helper then truncates its PID record. | Under the helper operation lock, refuse an already-live recorded tunnel before truncation. Retain a wrapper-side guard for unrecorded same-server clients before monitor launch. #44 covers the latter. | Yes: unchanged generated helper, sequential and concurrent stub starts. |
| B4 | medium | `auckland-vpn:1774–1779`, `:1714–1745` | Intent is checked only before healing. A user stop during credential lookup or the stop/start gap can finish successfully, then the monitor starts a new tunnel. | Recheck intent immediately before launch. Serialize wrapper lifecycle transactions and intent updates so a completed explicit stop cannot be followed by an already-admitted heal start. | Yes: blocking fake sudo/credential fixtures. |
| B5 | medium | `auckland-vpn:1590–1594`, `:1657–1662` | Expired circuits immediately reopen because the exhausted attempt count survives. #22 | Permit exactly one half-open attempt after cooldown; reopen only on its failure. | Yes: fake-clock state-machine tests. |
| B6 | medium | `auckland-vpn:1657`, `:1699–1702` | Attempts are charged before the network gate. Offline observations can exhaust the breaker without issuing any helper start. | Charge the retry budget only when a real restart is admitted; network deferral must not consume it. | Yes: network-not-ready fixture and sudo call count. |
| B7 | medium | `auckland-vpn:1706–1711`, `:1830–1832` | Stop-refused returns 3, but the caller discards that classification. The notification says “paused” without an immediate persisted pause. #23 | Preserve the return class; persist an open circuit and notify once on stop refusal. | Yes: refusing fake sudo. |
| B8 | medium | `auckland-vpn:1805`, `:1706–1745` | Missing-helper warning says healing is disabled, but the start phase still runs. #43 | Gate healing on helper availability, emit `heal=blocked reason=no-helper`, and issue no sudo requests. | Yes. |
| B9 | medium | `auckland-vpn:884` | Re-running setup-sudo truncates the PID file even when a tunnel is active, losing the helper’s stop target. | Refuse setup while the tunnel is running/starting, before installation; print the required stop → setup-sudo → start sequence. | Yes for wrapper refusal and installer call count. |
| B10 | medium | `auckland-vpn:1555–1560` | Deep health checks verify the internal probe route but not the DNS-server route. A resolver reachable outside this tunnel can contribute to a false healthy result. | Require the DNS-server route to use the selected tunnel interface. Tool failures should produce `unknown`, not actionable tunnel failure. | Yes: sourced route/probe fixtures. |
| B11 | low | `auckland-vpn:2086–2096` | Diagnose equates “DTLS enabled” with “DTLS established”, and absence of a logged DNS marker with proof that the server pushed no DNS. | Separate advertised/enabled transport from establishment evidence; report absent markers as “not observed in this log”. | Yes: enabled-only and absent-marker fixtures. |

**Details:**

- B2 reproduced: verification accepted `/bin/bash` as its “PID file” when supplied a connected marker. No process validation occurred.
- B5 reproduced: expired circuit state emitted another `state=circuit_open action=notify`, not a half-open restart.
- Failed manual starts leave wanted-up intent set (#81). That interpretation is defensible, but failure output should explicitly say monitoring may retry and identify `auckland-vpn stop` as cancellation.
- Capability checks remain incomplete: setup checks only `--pid-file`, while doctor checks executability (#26/#87). Require the fixed invocation’s capabilities before installation and report failures in doctor.

### (d) Docs-drift

| ID | Severity | File:line | What is wrong | Concrete fix desire | Existing seams? |
|---|---|---|---|---|---|
| D1 | low | `README.md:135`, `auckland-vpn:1000–1003` | README says `log` reads only the latest attempt; it tails the whole file. #76 | Document `status`/`diagnose` attempt scoping separately from cross-attempt `log` tailing. | Yes: two-attempt output fixture. |
| D2 | low | `README.md:150`, `auckland-vpn:1069–1070` | “Every other character passes unchanged” omits setup’s trimming of leading/trailing password whitespace. | State the setup normalization explicitly; do not promise verbatim password entry. | Yes: fake Keychain capture using synthetic input. |
| D3 | low | `docs/consults/openconnect-audit.md:58–64`, `:305–309`; `docs/consults/reliability.md:369–384` | Historical “current state” omits shipped `--non-inter` and staged vpnc-script. Monitor specification still implies jitter and other unshipped timing behavior. #77/#92 | Add a dated shipped-status inventory: implemented recommendations, open desires, exact staged path, no jitter, actual healthy-reset timing. Preserve the historical recommendations. | Static assertions plus state-machine tests. |
| D4 | low | `README.md:107–108`, `auckland-vpn:218–223` | Invalid startup configuration prevents help and the documented bare/unknown exit-2 behavior. Environment/config conflicts are also mislabeled as duplicate file lines. #86/#72 | Document startup-validation precedence; name environment-versus-file conflicts accurately and give `unset VPN_USER` where applicable. | Yes: executable subprocess tests. |

### (e) Test-honesty / coverage gaps

| ID | Severity | File:line | What is wrong | Concrete fix desire | Existing seams? |
|---|---|---|---|---|---|
| T1 | medium | `tests/run-tests.sh:954` | Calling the entire test through `(...) \|\| ...` suppresses `errexit` inside sourced production functions. Explicit failure markers help assertions, but do not reproduce executable failure behavior. | Add fresh executable subprocess coverage for EOF, failed reads and pipelines. Add a harness regression demonstrating that unexpected command failure cannot silently score green. | Yes. |
| T2 | medium | `tests/run-tests.sh:762–804` | Monitor’s only end-to-end heal test is dry-run and returns before actual lifecycle logic. #46 | Cover real non-dry-run fake-boundary paths: network deferral, missing credentials/helper, stop refusal, cancellation and success. Assert calls, return classes and persisted state. | Yes. |
| T3 | low | `tests/run-tests.sh:7`, `:752–756` | Predictable fixture directory can adopt stale contents. The injection probe checks—and may delete—shared `/tmp/pwned`. #79/#78 | Allocate a unique private sandbox; keep the injection sentinel inside it; never delete an external pre-existing path. | Yes. |
| T4 | medium | `tests/run-tests.sh:838–881`, `:681–757` | Coverage omits group-writable PATH policy, stale/foreign-PID stop refusal, expired circuits and doctor’s authorization result. #71/#28/#22/#89 | Add discriminating negative fixtures without patching the generated helper. Assert that unrelated processes remain alive and refused operations leave state unchanged. | Yes. |

**Tracker corrections:** do not implement these claims without reconciliation:

- **#74 is false:** `read -rs` already includes `-r`; backslashes are preserved.
- **#78’s inter-test export/PATH leakage claim is false:** each test executes in a subshell. Its external `/tmp/pwned` concern remains valid.
- **#91’s monitor-death claim is false on the shipped call path:** `if ! monitor_act` suppresses `errexit` through `monitor_heal`; missing TOTP reaches `heal=blocked reason=no-totp`. Explicit read-status handling is still useful.
- **#75’s printf-format claim is false:** the helper banner uses constant `'%s\n'`.
- **#30’s proposed wrapper-side rename cannot work in the root-owned log directory.** Preserve the directory boundary; design inode-preserving bounded retention separately.
- Do not blanket-exempt sticky writable directories as suggested by #88; sticky mode does not make arbitrary PATH descendants trustworthy.

GitHub Actions currently reports **0 runs**, so CI success remains unverified (#48). No certificate, MTU, DTLS-default or vpnc-script policy changes are justified here. Actual University reconnect failures and DNS restoration incidents remain **NEEDS-LOG**.

## Implement desires

1. **Reject unsafe setup destinations — S2.**
   Acceptance: environment-overridden helper installation exits nonzero with `setup-sudo requires the canonical helper path`; fake sudo records no call. Test: `test_setup_sudo_rejects_helper_override`. Hostile privilege review required.

2. **Close symlink trust-walk gaps — S1.**
   Acceptance: helper start refuses a binary reached through a writable link ancestor with `not root-trusted`; doctor reports that ancestor. Safe link chains still pass. Tests: `test_helper_rejects_writable_symlink_ancestor`, `test_doctor_checks_link_parent`. Hostile privilege review required.

3. **Remove connected-marker SIGPIPE failures — R1.**
   Acceptance: a large current attempt containing connection evidence verifies successfully and status prints `Connected as`; an old-attempt-only marker does not verify. Test: `test_large_attempt_marker_is_pipefail_safe`.

4. **Correct doctor’s sudo operands — B1.**
   Acceptance: fake sudo receives `-n`, `-l`, helper path, and action as separate arguments; permitted/denied fixtures produce the corresponding OK/FIX and exit status. Output does not overclaim passwordlessness. Test: `test_doctor_helper_authorization_contract`.

5. **Refuse a second recorded tunnel under the helper lock — B3.**
   Acceptance: a second sequential helper start exits nonzero with `already connected/starting`, launches no daemon, and preserves the original PID. Test: `test_helper_sequential_start_refused`. Hostile privilege review required.

6. **Make explicit stop cancel in-flight healing — B4.**
   Acceptance: stop during the controlled heal gap completes without a later helper start; monitor prints `intent-down` cancellation. Test: `test_stop_cancels_inflight_heal`.

7. **Allow one post-cooldown recovery attempt — B5.**
   Acceptance: expired circuit emits exactly one restart action; its failure reopens the circuit, while success clears it after the established healthy threshold. Test: `test_monitor_circuit_half_open`.

8. **Do not spend retries while offline — B6.**
   Acceptance: repeated network-not-ready passes print deferral, leave the attempt budget unchanged, and issue zero helper starts; restored readiness admits one attempt. Test: `test_monitor_network_deferral_preserves_budget`.