# Auckland VPN Test Architecture

## Recommendation

Use a small plain-Bash test runner initially. This repository has one Bash
program and one maintainer; the runner in `prototypes/tests/run-tests.sh` has no
framework dependency, runs on macOS's existing Bash, and makes subprocess and
environment isolation explicit. Keep each test in a named function and run the
function in a subshell so `set -euo pipefail`, `exit`, sourced globals, and
function overrides cannot leak into another test.

Promote to bats-core if the suite grows past roughly 30 tests or needs fixtures,
test filtering, and richer failure diagnostics. Bats is readable (`@test`,
`run`, `$status`, `$output`) and actively maintained, but adds a Homebrew/npm
installation and helper-library versioning. On macOS, avoid relying on GNU
utilities or a newer system Bash even under Bats: the product still runs under
`#!/usr/bin/env bash`, while `/bin/bash` is the old Apple-provided Bash 3.2.

Do not choose shunit2 here. Its xUnit-style API is less direct for a command-line
program, its setup/teardown conventions hide process boundaries that matter for
this script, and it provides little advantage over the current runner without
Bats's ecosystem and output.

## Pyramid

### Static checks: every change

Run `bash -n` and ShellCheck on both artifacts:

1. `bash -n auckland-vpn` and `shellcheck auckland-vpn` validate the wrapper.
2. Source the wrapper in a sandbox, point its resolved paths at executable
   stubs, run `generate_helper > helper`, then run `bash -n helper` and
   `shellcheck helper`. Checking only the generator cannot parse the heredoc
   body as the generated program; this is the check that catches a stray `;;`.
3. Add narrow grep lints for security rules that syntax tools cannot express:
   no `mktemp -d /tmp...`, no unscoped `pkill`, no sudoers line granting raw
   `openconnect` or `pkill`, and no `eval`/sourcing of the user config.

Custom lints should match unsafe syntax, not merely words in comments. Keep the
restricted sudoers contract test as the authoritative check for grants.

### Unit tests: sourced functions

Source `auckland-vpn` with a fresh `HOME`, `XDG_STATE_HOME`, and `VPN_USER` in a
subshell. The existing direct-execution guard makes this safe today.

Cleanly unit-testable now:

- `first_executable`, `load_config`, `write_secret_file`
- `attempt_log`, `tunnel_ip_from_log`, `last_log_error`
- `openconnect_supports_pid_file`
- `detect_legacy_rule`
- pure output/validation portions of `usage`, `require_*`, and status reporting

Testable with command fakes placed first on `PATH`:

- `running_vpn_pid` (`cat`, `ps`, `pgrep` behavior)
- `verify_tunnel_started` and `wait_until_vpn_gone` (`sleep` and process state)
- Keychain setup/lookup (`security`)
- Homebrew resolution (`brew`, `command -v`, executable fixture paths)

Functions needing a production seam for focused tests:

- `cmd_start`, `cmd_stop`, and `cmd_restart` combine policy, keychain, sudo,
  helper invocation, polling, and presentation.
- `cmd_setup_sudo` combines artifact creation, validation, privileged install,
  and legacy-rule scanning.
- The generated helper combines trust checks, credential input, process launch,
  pidfile polling, ownership changes, and stop escalation.

Do not mock every command inside these orchestration functions. Cover their
policy with contract/integration tests and extract only stable boundaries when
promoting the suite.

### Contract tests: fake sudo boundary

The contract is that the unprivileged wrapper may request exactly two privileged
operations: an immutable helper path followed by exactly `start` or `stop`.
Test these independent facts:

- Generated helper dispatch accepts one argument and only `start|stop`.
- Generated helper bakes fixed `%q`-escaped paths, protocol, server, username,
  secret, log, and pidfile; none are accepted from invocation arguments.
- Generated sudoers text is exactly
  `<user> ALL=(root) NOPASSWD: <helper> start, <helper> stop`.
- The sudoers text contains neither the openconnect path nor `pkill`.
- Wrapper calls are exactly `sudo -n "$HELPER_BIN" start|stop` and password is
  delivered only on stdin.

The prototype's fake `sudo` strips `-n` and executes the generated helper as the
current user. This exercises the boundary but does not claim to test real
sudoers parsing, root ownership, or privilege transitions.

#### Recommended seam

Add `AUCKLAND_VPN_HELPER_BIN` as a wrapper-only override, honored only when the
wrapper is not privileged:

```bash
if [ "$(id -u)" -ne 0 ] && [ -n "${AUCKLAND_VPN_HELPER_BIN:-}" ]; then
  HELPER_BIN="$AUCKLAND_VPN_HELPER_BIN"
fi
```

Risk: an attacker controlling a user's environment can select a different
program for that user to ask sudo to execute. This does not expand privilege:
sudoers still authorizes only the installed absolute helper path, so fake paths
are rejected by real sudo. Do not pass this variable through sudo (`SETENV`) and
do not let the generated helper read it.

An even smaller alternative is no production override: source the wrapper and
assign `HELPER_BIN` in the test, as the prototype does. That works for function
tests but cannot black-box test the executable command dispatch.

Do **not** add `AUCKLAND_VPN_TEST_MODE` to the privileged helper. Any behavior
switch inherited across sudo creates a second, less-defended root execution
mode; a future sudoers `SETENV` change or preserved environment could turn a
test convenience into a bypass. The generated helper should remain unaware of
tests.

For sudo itself, prefer a wrapper-only `AUCKLAND_VPN_SUDO_BIN` absolute-path
override over changing `PATH` if black-box tests are required. Validate that it
is non-empty and use it only in the unprivileged wrapper. Risk is similarly
bounded by real sudoers, but the override could execute arbitrary code as the
current user; that is already possible to anyone controlling that user's
environment. Never bake it into the helper or sudoers.

### Integration tests: generated helper plus stub openconnect

Build an executable openconnect stub in a private sandbox and assign
`OPENCONNECT_BIN` **after sourcing** but **before `generate_helper`**. This is
necessary today because startup resolution prefers fixed
`/opt/homebrew/bin/openconnect` and `/usr/local/bin/openconnect` before `PATH`.
Also point `SCRIPT_PATH`, `SECRET_FILE`, `LOG_FILE`, `PID_FILE`, and `HELPER_BIN`
at sandbox paths before generation.

The stub must:

- advertise `--pid-file` for the generator prerequisite check;
- record every argv element and the password received on stdin;
- on success, write the requested pidfile and a strong current-attempt marker
  such as `Connected as 10.20.30.40`;
- on auth failure, write `Invalid password; authentication failed` and exit
  nonzero;
- optionally launch a long-lived child whose command line contains
  `openconnect` and the fixed server, enabling a complete helper `stop` test.

The promoted integration suite should cover start success, auth failure,
missing pidfile timeout with `sleep` faked, exact argv, password re-feed, log
rotation, stale successful marker rejection, exact-PID stop, PID reuse refusal,
and TERM-to-KILL escalation. The prototype success test starts a long-lived stub
whose command line is PID-verifiable, then stops it and checks process and
pidfile removal. Timeout, PID reuse, and forced escalation remain to add.

Path injection should become explicit for black-box tests. Add a wrapper-only
`AUCKLAND_VPN_OPENCONNECT_BIN` override before normal resolution, but accept it
only when `id -u != 0`, require an absolute executable path, and bake the
resolved result into the helper exactly as production does. Risk: the user can
choose what the helper executes as root after running `setup-sudo`. This is not
safe as a general production environment option because the sudo installation
could preserve that selection. Prefer exposing it only in an uninstalled
`generate-helper-for-test` harness or continue assigning the variable after
sourcing. Never let the installed helper consult this environment variable.

### End-to-end smoke: manual only

Keep one opt-in script or documented checklist that uses real Keychain, real
sudoers, the installed root-owned helper, the University endpoint, TOTP, DNS,
routes, status, and stop. Require an explicit flag such as
`AUCKLAND_VPN_REAL_E2E=1`; never run it from the normal test runner or CI. It
touches credentials, prompts for privilege, mutates host networking, and depends
on an external service, so it is a release smoke test rather than a deterministic
automated test.

## CI on GitHub Actions

Use a `macos-latest` job because helper trust checks use BSD/macOS `stat -f`,
the product depends on macOS commands, and Linux alone would miss portability
errors. Install ShellCheck with Homebrew, then run
`prototypes/tests/run-tests.sh`. A second Ubuntu ShellCheck-only job is optional,
not a substitute for macOS.

Runs without root/sudo in CI:

- wrapper and generated-artifact syntax, ShellCheck, and grep lints;
- sourced unit tests under sandboxed home/state directories;
- generated-helper contract tests with fake sudo;
- stub-openconnect start/failure integration tests using sandbox paths;
- pid/process tests that operate only on test-owned processes.

Does not run in ordinary CI:

- installation into `/private/etc` or `/etc/sudoers.d`;
- real `visudo` plus authorization behavior for the installed exact-argument
  sudoers rule;
- root ownership/mode enforcement and root-to-user `chown` behavior;
- trust-walk cases requiring root-owned fixture trees or alternate users/groups;
- real Keychain GUI authorization prompts;
- real openconnect, VPN authentication, DNS/routes, or network access;
- the manual end-to-end smoke.

GitHub-hosted macOS runners may technically offer passwordless administrative
sudo, but tests must not depend on it. It would test GitHub's broad runner policy,
not this project's installed exact-command sudoers boundary, and privileged
network mutations are unsafe and nondeterministic.

## Test Inventory

| Test name | Level | Bug class caught | CI |
|---|---|---|---|
| `test_static_wrapper` | Static | Wrapper syntax/ShellCheck defects; shared `/tmp` staging; obvious unscoped kill | Yes |
| `test_static_generated_helper` | Static | Invalid emitted Bash such as a stray `;;`; generated ShellCheck defects; helper `pkill` | Yes |
| `test_config_rejects_shell_code` | Unit | Config parser regression to execution or acceptance of unsupported commands | Yes |
| `test_config_rejects_conflicting_users` | Unit | Ambiguous duplicate identity accepted | Yes |
| `test_attempt_log_scopes_latest_banner` | Unit | Old successful connection marker validating a failed retry | Yes |
| `test_tunnel_ip_from_log` | Unit | Failure to extract current-attempt tunnel IPv4 | Yes |
| `test_privileged_command_contract` | Contract | Helper accepts extra operations; sudo grant broadens to raw openconnect/pkill | Yes |
| `test_start_success_with_stub_openconnect` | Integration | Wrong fixed argv, lost stdin password, missing pid/log verification, wrong success output, or exact-PID stop failure | Yes |
| `test_start_auth_failure_with_stub_openconnect` | Integration | Authentication failure reported as connected or useful log detail hidden | Yes |
| Helper PID reuse/escalation fixtures | Integration (promote next) | PID reuse, stale pidfile, failed TERM-to-KILL escalation | Yes |
| Root install/ownership/sudoers authorization | System | Wrong owner/mode, invalid sudoers, environment preservation across sudo | No; dedicated disposable Mac only |
| Real University connection smoke | E2E | Endpoint/certificate/TOTP/DNS/route behavior | No; manual only |

## Promotion Plan

1. Move the prototype runner to `tests/run-tests.sh` and fixtures to
   `tests/fixtures/`; add the macOS CI job.
2. Make generated-artifact `bash -n` and ShellCheck mandatory. This needs no
   production seam because sourcing and post-source variable assignment work.
3. Add a test-owned long-lived process fixture for helper stop and escalation.
   Keep the helper unchanged; fake `ps`, `kill`, and `sleep` only if real
   test-owned process behavior cannot be made deterministic.
4. Add wrapper-only helper/sudo command overrides only if executable-level
   black-box coverage is worth the added public surface. Never add test mode or
   path overrides to the generated privileged helper.
5. Keep real sudo installation and real VPN checks outside normal automation,
   with an explicit manual opt-in and cleanup checklist.
