#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
CLI="$ROOT/auckland-vpn"
TMP_ROOT="$TEST_DIR/.tmp.$$"
PASSED=0
FAILED=0

mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf '    %s\n' "$*" >&2
  return 1
}

assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) fail "expected output to contain: $2" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected output not to contain: $2" ;;
    *) return 0 ;;
  esac
}

new_sandbox() {
  local name="$1"
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home" "$dir/state" "$dir/bin"
  printf '%s\n' "$dir"
}

source_cli() {
  export HOME="$1/home"
  export XDG_STATE_HOME="$1/state"
  export VPN_USER=""
  # shellcheck disable=SC1090
  source "$CLI"
}

make_openconnect_stub() {
  local path="$1" mode="${2:-success}"
  # Self-contained stub: records next to itself (NOT via env vars — the
  # hardened helper launches openconnect through 'env -i', which correctly
  # strips any environment the test exported). Behaviour is baked in.
  cat >"$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
recdir="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "--help" ]; then
  echo 'usage: openconnect --pid-file=FILE'
  exit 0
fi
STUB
  printf 'OC_STUB_MODE=%q\n' "$mode" >>"$path"
  cat >>"$path" <<'STUB'
if [ "$OC_STUB_MODE" = "slow-start" ]; then
  sleep 2   # hold the caller's helper (and its operation lock) briefly
fi
if [ "$OC_STUB_MODE" = "hang" ]; then
  # Foreground stub that stays busy so a signal can arrive mid-operation.
  IFS= read -r password || true
  printf '%s\n' "$@" >"$recdir/stub.argv"
  sleep 2
  exit 0
fi
if [ "${1:-}" = "--stub-daemon" ]; then
  if [ "$OC_STUB_MODE" = "ignore-term" ]; then
    trap '' TERM INT   # survive SIGTERM: exercises the no-SIGKILL stop timeout
  else
    trap 'exit 0' TERM INT
  fi
  while :; do sleep 1; done
fi
printf '%s\n' "$@" >"$recdir/stub.argv"
# Emulate openconnect's @file handling: READ the token file, record its mode
# and contents for assertions, then unlink it.
for arg in "$@"; do
  case "$arg" in
    --token-secret=@*)
      tokfile="${arg#--token-secret=@}"
      { printf 'mode=%s\n' "$(stat -f '%Lp' "$tokfile")"; cat "$tokfile"; } >"$recdir/stub.token"
      rm -f "$tokfile"
      ;;
  esac
done
IFS= read -r password || true
printf '%s\n' "$password" >"$recdir/stub.stdin"
if [ "$OC_STUB_MODE" = "auth-fail" ]; then
  echo 'Invalid password; authentication failed'
  exit 1
fi
server="${*: -1}"
"$0" --stub-daemon "$server" >/dev/null 2>&1 &
daemon_pid=$!
for arg in "$@"; do
  case "$arg" in
    --pid-file=*) printf '%s\n' "$daemon_pid" >"${arg#--pid-file=}" ;;
  esac
done
echo 'Connected as 10.20.30.40'
STUB
  chmod +x "$path"
}

make_fake_sudo() {
  local path="$1"
  cat >"$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# Emulate sudo's environment contract: SUDO_UID/SUDO_GID are always exported
# to the command, and the generated helper verifies them against baked values.
export SUDO_UID="$(id -u)" SUDO_GID="$(id -g)"
if [ "${1:-}" = "-n" ]; then shift; fi
exec "$@"
STUB
  chmod +x "$path"
}

configure_generated_helper() {
  local box="$1"
  OPENCONNECT_BIN="$box/bin/openconnect"
  SCRIPT_PATH="$box/bin/vpnc-script"
  STAGED_VPNC_SCRIPT="$box/helper-dir/vpnc-script"
  HELPER_DIR="$box/helper-dir"
  HELPER_BIN="$HELPER_DIR/helper"
  PID_FILE="$HELPER_DIR/vpn.pid"
  STATE_DIR="$box/state/auckland-vpn"
  LOG_DIR="$box/var-log/auckland-vpn"
  LOG_FILE="$LOG_DIR/auckland-vpn.log"
  CONFIG_DIR="$box/home/.config/auckland-vpn"
  SECRET_FILE="$CONFIG_DIR/totp-secret"
  PASSWORD_FILE="$CONFIG_DIR/vpn-password"
  VPN_USER="student@example.test"
  mkdir -p "$HELPER_DIR" "$STATE_DIR" "$CONFIG_DIR" "$LOG_DIR"
  printf '#!/bin/sh\n' >"$SCRIPT_PATH"
  printf '#!/bin/sh\n' >"$STAGED_VPNC_SCRIPT"
  chmod +x "$SCRIPT_PATH" "$STAGED_VPNC_SCRIPT"
  # Simulate setup-sudo's install step: a log file already created owned by
  # the invoking user, mode 600 (the root-owned parent dir is production-
  # only; the helper just appends to whatever regular file sits there).
  : >"$LOG_FILE"
  chmod 600 "$LOG_FILE"
  # ... and the pidfile: PRE-CREATED mode 644, kept across stops. Owned by
  # the invoking user here rather than root — production keeps it
  # root:wheel; the helper's shared validator accepts the pinned caller uid,
  # which is exactly what keeps this suite runnable without sudo.
  : >"$PID_FILE"
  chmod 644 "$PID_FILE"
  printf 'TESTTOTSECRET\n' >"$SECRET_FILE"
  printf 'correct horse battery staple\n' >"$PASSWORD_FILE"
  generate_helper >"$HELPER_BIN"
  chmod +x "$HELPER_BIN"
}

test_static_wrapper() {
  local hit
  command -v shellcheck >/dev/null || fail 'shellcheck is required'
  bash -n "$CLI" || return
  shellcheck "$CLI" || return
  ! grep -nE 'mktemp -d[[:space:]]+/tmp|sudo[[:space:]]+pkill[[:space:]]+(-[A-Za-z]*[[:space:]]+)*openconnect' "$CLI" \
    || fail 'unsafe temp directory or unscoped pkill found'
  # Every privileged invocation must stay interceptable via the wrapper-only
  # $SUDO_BIN seam (issue #16): no literal 'sudo' command may bypass it.
  hit="$(grep -nE 'sudo (-n )?"\$HELPER_BIN"|\| sudo |sudo (sh|pkill) ' "$CLI" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [ -z "$hit" ] || fail "sudo call bypasses the \$SUDO_BIN seam: $hit"
}

test_static_generated_helper() {
  local box helper util hit
  box="$(new_sandbox static-helper)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  helper="$HELPER_BIN"
  bash -n "$helper" || return
  shellcheck "$helper" || return
  ! grep -nE 'mktemp -d[[:space:]]+/tmp|(^|[[:space:]])pkill([[:space:]]|$)' "$helper" \
    || fail 'unsafe construct found in generated helper'
  head -n 1 "$helper" | grep -q '^#!/bin/bash -p$' \
    || fail 'helper must start privileged: #!/bin/bash -p'
  grep -q '/usr/bin/env -i' "$helper" \
    || fail 'openconnect must be launched via env -i'
  grep -q 'unset BASH_ENV ENV CDPATH GLOBIGNORE' "$helper" \
    || fail 'helper must sanitize dangerous environment variables'
  ! grep -q 'SECRET_FILE\|PASSWORD_FILE\|CONFIG_DIR\|XDG_STATE' "$helper" \
    || fail 'helper must not reference user-owned credential/state paths'
  # External utilities must never resolve through (or be planted into) PATH;
  # bash builtins (echo/printf/read/kill/trap/umask/unset) are exempt.
  for util in stat readlink dirname ps rm rmdir date chmod chown mktemp mkdir sleep basename cat env; do
    hit="$(grep -nE "(^|[^/A-Za-z0-9_])${util}([[:space:]]|;|\)|\$)" "$helper" \
      | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    # A bare-word utility anywhere outside a comment fails the test LOUDLY
    # (the old form only failed when the LAST util in the list had a hit).
    if [ -n "$hit" ]; then fail "unqualified '$util' invocation in helper: $hit"; return 1; fi
  done
}

test_config_rejects_shell_code() {
  local box output status
  box="$(new_sandbox config-shell)"
  mkdir -p "$box/home/.config/auckland-vpn"
  printf 'touch %s/pwned\n' "$box" >"$box/home/.config/auckland-vpn/config"
  output="$(HOME="$box/home" XDG_STATE_HOME="$box/state" VPN_USER='' bash -c 'source "$1"' _ "$CLI" 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'malicious config was accepted'
  [ ! -e "$box/pwned" ] || fail 'config content was executed'
  assert_contains "$output" 'unsupported line'
}

test_config_rejects_conflicting_users() {
  local box output status
  box="$(new_sandbox config-duplicate)"
  mkdir -p "$box/home/.config/auckland-vpn"
  printf 'VPN_USER=alice\nVPN_USER=bob\n' >"$box/home/.config/auckland-vpn/config"
  output="$(HOME="$box/home" XDG_STATE_HOME="$box/state" VPN_USER='' bash -c 'source "$1"' _ "$CLI" 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'conflicting usernames were accepted'
  assert_contains "$output" 'duplicate conflicting VPN_USER lines'
}

test_attempt_log_scopes_latest_banner() {
  local box output
  box="$(new_sandbox attempt-log)"
  source_cli "$box"
  LOG_FILE="$box/attempt.log"
  cat >"$LOG_FILE" <<'LOG'
==== auckland-vpn start old ====
Connected as 10.0.0.1
==== auckland-vpn start new ====
Invalid password
LOG
  output="$(attempt_log)"
  assert_contains "$output" 'Invalid password'
  assert_not_contains "$output" '10.0.0.1'
}

test_tunnel_ip_from_log() {
  local box output
  box="$(new_sandbox tunnel-ip)"
  source_cli "$box"
  LOG_FILE="$box/tunnel.log"
  cat >"$LOG_FILE" <<'LOG'
==== auckland-vpn start now ====
Connected as 172.19.8.7, using SSL
LOG
  output="$(tunnel_ip_from_log)"
  [ "$output" = '172.19.8.7' ] || fail "unexpected tunnel IP: $output"
}

test_privileged_command_contract() {
  local box helper rule expected
  box="$(new_sandbox contract)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  helper="$(generate_helper)"
  assert_contains "$helper" '[ $# -eq 1 ] || usage'
  assert_contains "$helper" 'start) cmd_start ;;'
  assert_contains "$helper" 'stop)  cmd_stop ;;'
  # Audit P1 (issue #15): the fixed argv must fail loudly instead of waiting
  # for input a stdin-less root process can never supply.
  assert_contains "$helper" '--non-inter'
  assert_not_contains "$helper" 'pkill '

  cat >"$box/bin/visudo" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat >"$box/bin/sudo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = sh ] || exit 2
cp "$(dirname "$2")/auckland-vpn" "$CONTRACT_CAPTURE"
STUB
  chmod +x "$box/bin/visudo" "$box/bin/sudo"
  export PATH="$box/bin:$PATH" CONTRACT_CAPTURE="$box/captured-sudoers"
  cmd_setup_sudo >/dev/null
  rule="$(cat "$CONTRACT_CAPTURE")"
  # NOSETENV: sudo must never honour SETENV or a user-supplied environment.
  # secure_path is command-scoped defence in depth (validated by real
  # visudo -cf during setup; the stub here only checks the emitted text).
  expected="$(whoami) ALL=(root) NOPASSWD:NOSETENV: $HELPER_BIN start, $HELPER_BIN stop
Defaults!$HELPER_BIN secure_path=\"/usr/bin:/bin:/usr/sbin:/sbin\""
  [ "$rule" = "$expected" ] || fail 'sudoers contract changed'
  assert_not_contains "$rule" "$OPENCONNECT_BIN"
  assert_not_contains "$rule" 'pkill'
  case "$rule" in
    *NOPASSWD:NOSETENV:*) : ;;
    *) fail 'sudoers rule lost the NOSETENV tag' ;;
  esac
}

test_start_success_with_stub_openconnect() {
  local box output stop_output args pid
  box="$(new_sandbox integration-success)"
  make_openconnect_stub "$box/bin/openconnect"
  make_fake_sudo "$box/bin/sudo"
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH"
  output="$(cmd_start 2>&1)" || fail "start unexpectedly failed: $output"
  assert_contains "$output" 'Tunnel IP: 10.20.30.40'
  # Monitor intent (issue #14): a successful start marks the VPN wanted-up.
  [ -f "$STATE_DIR/monitor.enabled" ] || fail 'start did not mark monitor intent (monitor.enabled)'
  args="$(cat "$box/bin/stub.argv")"
  assert_contains "$args" '--protocol=fortinet'
  assert_contains "$args" '--passwd-on-stdin'
  # Audit P1 (issue #15): the launched process itself must carry --non-inter.
  assert_contains "$args" '--non-inter'
  assert_contains "$args" "--pid-file=$PID_FILE"
  assert_contains "$args" 'connectvpn.auckland.ac.nz/client'
  [ "$(cat "$box/bin/stub.stdin")" = 'correct horse battery staple' ] \
    || fail 'password was not re-fed to openconnect stdin'
  # The stub READ the @token file itself: its recorded snapshot must show
  # mode 600 (umask 077 + mktemp make it so, even with no runtime chmod)
  # and the exact expected TOTP value.
  [ "$(cat "$box/bin/stub.token")" = "$(printf 'mode=600\nTESTTOTSECRET')" ] \
    || fail "stub saw wrong token file contents/mode: $(cat "$box/bin/stub.token" 2>/dev/null || true)"
  # Root-side hygiene: no operation lock left held, no token temp file left
  # behind, pidfile world-readable (root-owned in production; wrapper reads).
  [ ! -e "$HELPER_DIR/operation.lock" ] || fail 'start left the operation lock behind'
  [ -z "$(ls "$HELPER_DIR" | grep '^token\.')" ] || fail 'start left a token temp file behind'
  [ "$(stat -f '%Lp' "$PID_FILE")" = '644' ] || fail 'pidfile not mode 644'
  args="$(cat "$box/bin/stub.argv")"
  case "$args" in
    *"--token-secret=@$HELPER_DIR/token."*) : ;;
    *) fail "token secret not passed via HELPER_DIR temp file: $args" ;;
  esac
  pid="$(cat "$PID_FILE")"
  stop_output="$(cmd_stop 2>&1)" || fail "stop unexpectedly failed: $stop_output"
  assert_contains "$stop_output" 'Disconnected.'
  # The pidfile is persistent infrastructure: stop KEEPS it (root-owned 644
  # in production) holding the now-dead PID; readers tolerate stale records
  # and the next start truncates it.
  [ -s "$PID_FILE" ] || fail 'stop must keep the non-empty pidfile in place'
  [ "$(stat -f '%Lp' "$PID_FILE")" = '644' ] || fail 'stop changed the pidfile mode'
  # ...and an explicit user stop clears the monitor's wanted-up intent.
  [ ! -e "$STATE_DIR/monitor.enabled" ] || fail 'stop did not clear monitor intent'
  ! ps -p "$pid" >/dev/null 2>&1 || fail 'stop left the stub process running'
}

test_start_auth_failure_with_stub_openconnect() {
  local box output status
  box="$(new_sandbox integration-auth-fail)"
  make_openconnect_stub "$box/bin/openconnect" auth-fail
  make_fake_sudo "$box/bin/sudo"
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH"
  output="$(cmd_start 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'authentication failure reported success'
  assert_contains "$output" 'Invalid password; authentication failed'
  assert_contains "$output" 'Connection failed. Full log'
}

# The helper consumes TWO stdin records (password, then TOTP secret) read by
# the WRAPPER — root must open no user-owned path. Runs the generated helper
# DIRECTLY under env -i with a minimal environment to prove it depends on
# nothing inherited.
test_helper_two_record_stdin_and_token_file() {
  local box output status args tokfiles
  box="$(new_sandbox helper-stdin)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH"

  # A missing second record must fail loudly, before any launch. (It runs
  # first simply because later cases mutate state; the shared pidfile
  # validator accepts caller-owned pidfiles, so ordering no longer matters
  # for it.)
  output="$(printf '%s\n' 'password-only' \
    | env -i PATH=/usr/bin:/bin SUDO_UID="$(id -u)" SUDO_GID="$(id -g)" \
        "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'missing TOTP record was accepted'
  assert_contains "$output" 'no TOTP secret received on stdin'

  # A mismatched invoking identity must be refused outright.
  output="$(printf '%s\n%s\n' p t \
    | env -i PATH=/usr/bin:/bin SUDO_UID=999 SUDO_GID=999 \
        "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'mismatched SUDO_UID was accepted'
  assert_contains "$output" 'does not match the installed caller'

  output="$(printf '%s\n%s\n' 'correct horse battery staple' 'TESTTOTSECRET' \
    | env -i PATH=/usr/bin:/bin \
        SUDO_UID="$(id -u)" SUDO_GID="$(id -g)" \
        "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -eq 0 ] || fail "direct helper start failed: $output"
  assert_contains "$output" 'VPN started'
  assert_contains "$(cat "$box/bin/stub.stdin")" 'correct horse battery staple'
  [ "$(cat "$box/bin/stub.token")" = "$(printf 'mode=600\nTESTTOTSECRET')" ] \
    || fail 'token file contents/mode wrong as seen by the stub reader'
  args="$(cat "$box/bin/stub.argv")"
  case "$args" in
    *"--token-secret=@$HELPER_DIR/token."*) : ;;
    *) fail "token secret not passed via HELPER_DIR temp file: $args" ;;
  esac
  # Token temp files are trap-removed; the operation lock is released.
  tokfiles="$(ls "$HELPER_DIR" | grep '^token\.' || true)"
  [ -z "$tokfiles" ] || fail "token temp file left behind: $tokfiles"
  [ ! -e "$HELPER_DIR/operation.lock" ] || fail 'operation lock left behind'

  # Teardown: stop the tunnel started above.
  output="$(env -i PATH=/usr/bin:/bin SUDO_UID="$(id -u)" SUDO_GID="$(id -g)" \
    "$HELPER_BIN" stop 2>&1)" || fail "helper stop failed: $output"
  assert_contains "$output" 'Disconnected.'
}

# Root-side mutual exclusion: while one helper operation runs (slow stub
# holds the lock), a second must die with a clear error; exactly ONE tunnel
# results, and the lock is released afterwards.
test_concurrent_start_refused_by_lock() {
  local box first_pid second_output second_status daemon_count tries=0
  box="$(new_sandbox helper-lock)"
  make_openconnect_stub "$box/bin/openconnect" slow-start
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH"

  export SUDO_UID="$(id -u)" SUDO_GID="$(id -g)"
  printf '%s\n%s\n' pass tok \
    | "$HELPER_BIN" start >/dev/null 2>&1 &
  first_pid=$!
  while [ ! -d "$HELPER_DIR/operation.lock" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -d "$HELPER_DIR/operation.lock" ] || fail 'first helper never held the operation lock'

  second_output="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)"
  second_status=$?
  [ "$second_status" -ne 0 ] || fail 'second concurrent start was not refused'
  assert_contains "$second_output" 'operation is in progress'

  wait "$first_pid" || fail 'first helper start failed while holding lock' 
  [ ! -e "$HELPER_DIR/operation.lock" ] || fail 'lock not released after completion'

  daemon_count="$(pgrep -f "$box/bin/openconnect" | wc -l | tr -d ' ')"
  [ "$daemon_count" = "1" ] || fail "expected exactly 1 tunnel process, got $daemon_count"

  env -i PATH=/usr/bin:/bin SUDO_UID="$(id -u)" SUDO_GID="$(id -g)" \
    "$HELPER_BIN" stop >/dev/null 2>&1 || true
}

# A SIGTERM arriving MID-OPERATION must tear everything down and exit 143 —
# never resume a half-finished privileged run (signals map to exit codes;
# only the EXIT trap releases the lock/token).
test_sigterm_mid_operation_exits_cleanly() {
  local box hpid status tokfile tries=0
  box="$(new_sandbox sigterm-trap)"
  make_openconnect_stub "$box/bin/openconnect" hang
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH"
  export SUDO_UID="$(id -u)" SUDO_GID="$(id -g)"

  printf '%s\n%s\n' pass tok | "$HELPER_BIN" start >/dev/null 2>&1 &
  hpid=$!
  while [ "$tries" -lt 50 ]; do
    tokfile="$(ls "$HELPER_DIR" 2>/dev/null | grep '^token\.' || true)"
    [ -n "$tokfile" ] && break
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -n "$tokfile" ] || fail 'helper never reached token creation'

  kill -TERM "$hpid"
  wait "$hpid" 2>/dev/null
  status=$?
  [ "$status" -eq 143 ] || fail "expected exit 143 after SIGTERM, got $status"
  # The EXIT trap ran: no usable privileged state survives the signal.
  [ ! -e "$HELPER_DIR/operation.lock" ] || fail 'SIGTERM left the operation lock behind'
  tokfile="$(ls "$HELPER_DIR" 2>/dev/null | grep '^token\.' || true)"
  [ -z "$tokfile" ] || fail "SIGTERM left the token temp file behind: $tokfile"
}

# Stale-lock takeover: a leftover lock dir must be recoverable WITHOUT ever
# deleting a possibly-live lock on sight. A dead-holder marker is taken over
# immediately (and logged); an EMPTY marker is waited out (~2s of retries,
# the mkdir→write-pid window) before an abandoned-lock takeover.
test_stale_lock_takeover() {
  local box out status dead_pid
  box="$(new_sandbox stale-lock)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH"
  export SUDO_UID="$(id -u)" SUDO_GID="$(id -g)"

  # Scenario 1: marker names a provably DEAD holder -> immediate takeover.
  true & dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  mkdir "$HELPER_DIR/operation.lock"
  printf '%s\n' "$dead_pid" >"$HELPER_DIR/operation.lock/pid"
  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -eq 0 ] || fail "start did not take over a dead-holder lock: $out"
  assert_contains "$out" 'is dead — taking over the stale lock'
  [ ! -e "$HELPER_DIR/operation.lock" ] || fail 'lock leaked after successful start'
  env -i PATH=/usr/bin:/bin SUDO_UID="$(id -u)" SUDO_GID="$(id -g)" \
    "$HELPER_BIN" stop >/dev/null 2>&1 || true

  # Scenario 2: EMPTY marker (an owner may sit in its mkdir→write-pid
  # window): never removed on sight; takeover only after the retry grace.
  mkdir "$HELPER_DIR/operation.lock"
  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -eq 0 ] || fail "start did not take over an abandoned empty lock: $out"
  assert_contains "$out" 'still empty after grace'
  [ ! -e "$HELPER_DIR/operation.lock" ] || fail 'lock leaked after successful start'
  env -i PATH=/usr/bin:/bin SUDO_UID="$(id -u)" SUDO_GID="$(id -g)" \
    "$HELPER_BIN" stop >/dev/null 2>&1 || true
}

# Installer quoting regression: site values must travel as POSITIONAL
# PARAMETERS of a static installer body — never interpolated into the
# emitted text (an apostrophe in any path used to break installed lines
# silently).
test_installer_takes_paths_as_parameters() {
  local box out status direct captured args body
  box="$(new_sandbox installer-quote)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"

  # Adversarial vpnc-script path: apostrophe AND space.
  SCRIPT_PATH="$box/od'd path/vpnc-script"
  mkdir -p "$box/od'd path"
  cp "$box/bin/vpnc-script" "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"

  # Direct generator output must be syntactic and shellcheck-clean.
  direct="$box/direct-install.sh"
  generate_installer >"$direct"
  sh -n "$direct" || return
  shellcheck "$direct" || return

  # Full setup-sudo under stub visudo/sudo; capture what sudo was handed.
  mkdir -p "$box/captured"
  cat >"$box/bin/visudo" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat >"$box/bin/sudo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = sh ] || exit 2
inst="$2"; shift 2
printf '%s\n' "$inst" >"$QUOTING_CAPTURE/installer.path"
printf '%s\n' "$@" >"$QUOTING_CAPTURE/installer.args"
cp "$inst" "$QUOTING_CAPTURE/install.sh"
STUB
  chmod +x "$box/bin/visudo" "$box/bin/sudo"
  export PATH="$box/bin:$PATH" QUOTING_CAPTURE="$box/captured"
  out="$(cmd_setup_sudo 2>&1)"
  status=$?
  [ "$status" -eq 0 ] || fail "setup-sudo failed: $out"

  captured="$box/captured/install.sh"
  sh -n "$captured" || return
  cmp -s "$direct" "$captured" || fail 'installer is not static/deterministic'
  body="$(cat "$captured")"
  # NO literal interpolated path anywhere in the emitted body — including
  # the adversarial apostrophe one.
  assert_not_contains "$body" "$SCRIPT_PATH"
  assert_not_contains "$body" "$LOG_FILE"
  assert_not_contains "$body" "$HELPER_BIN"
  assert_not_contains "$body" "$STATE_DIR"
  # The values travelled as arguments instead.
  args="$(cat "$box/captured/installer.args")"
  assert_contains "$args" "$SCRIPT_PATH"
  assert_contains "$args" "$PID_FILE"
  assert_contains "$args" "$SUDOERS_FILE"
}

# A stubborn openconnect that ignores SIGTERM must NOT be escalated to
# SIGKILL (recycled-PID hazard): stop reports honestly, exits non-zero, and
# removes nothing.
test_stop_timeout_reports_honestly_without_sigkill() {
  local box out status daemon_pid
  box="$(new_sandbox stop-timeout)"
  make_openconnect_stub "$box/bin/openconnect" ignore-term
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH"
  export SUDO_UID="$(id -u)" SUDO_GID="$(id -g)"

  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)" \
    || fail "start failed: $out"
  daemon_pid="$(cat "$PID_FILE")"
  ps -p "$daemon_pid" >/dev/null 2>&1 || fail 'stub daemon not running before stop'

  out="$("$HELPER_BIN" stop 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'stop reported success despite a live process'
  assert_contains "$out" 'did not exit within ~10s of SIGTERM'
  assert_contains "$out" 'NOT force-killed'
  assert_contains "$out" 'recycled PID'
  # No SIGKILL escalation happened: the process is STILL ALIVE after the
  # timeout, and the persistent pidfile was left untouched.
  ps -p "$daemon_pid" >/dev/null 2>&1 \
    || fail 'process died anyway — SIGKILL escalation regressed'
  [ "$(cat "$PID_FILE")" = "$daemon_pid" ] || fail 'stop mutated the pidfile on timeout'

  # Teardown: the TEST kills its own stubborn daemon (the helper rightly
  # refuses to).
  kill -9 "$daemon_pid" 2>/dev/null || true
}

# ---- Monitor / auto-heal (issue #14) -----------------------------------------
# Thresholds must be exported BEFORE source_cli: the wrapper freezes their
# ${VAR:-default} values at source time (exactly like the prototype did).

# Pure classifier matrix + hysteresis + backoff ladder + circuit breaker,
# driven through the sourced functions (prototype test pattern reused).
test_monitor_state_machine_transitions() {
  local box now r delay i expected
  box="$(new_sandbox monitor-machine)"
  export RECONNECT_GRACE=90 NETWORK_SETTLE_GRACE=30 DEGRADED_THRESHOLD=2 \
    DEGRADED_GRACE=120 MAX_RESTART_ATTEMPTS=7 CIRCUIT_COOLDOWN=3600 \
    BACKOFF_CAP=900 AUCKLAND_VPN_DRY_RUN=1
  source_cli "$box"
  ensure_state_dir   # save_monitor_state writes below $STATE_DIR

  # Classifier matrix (prototype contract).
  [ "$(classify_state 1 1 1 1 1)" = healthy ]      || fail 'all-ok must classify healthy'
  [ "$(classify_state 1 1 1 0 1)" = degraded ]     || fail 'direct-DNS failure must classify degraded'
  [ "$(classify_state 1 1 1 1 0)" = degraded ]     || fail 'system-resolver failure must classify degraded'
  [ "$(classify_state 1 0 0 1 1)" = reconnecting ] || fail 'missing tunnel/route must classify reconnecting'
  [ "$(classify_state 0 1 1 1 1)" = dead ]         || fail 'invalid PID must classify dead'

  # Degraded hysteresis: ONE consecutive failure waits; the SECOND crosses
  # DEGRADED_THRESHOLD (and, with the grace window aged, becomes a restart).
  # shellcheck disable=SC2034  # seeds for state_machine_step's globals
  current_state=unknown bad_since=0 degraded_count=0 restart_attempts=0
  # shellcheck disable=SC2034  # seeds for state_machine_step's globals
  next_attempt=0 circuit_until=0 healthy_count=0
  now="$(date +%s)"
  # NOTE: captured via redirect, NOT command substitution — $( ) would run
  # the step in a subshell and discard the counter mutations under test.
  state_machine_step degraded "$now" >"$box/rec"
  r="$(cat "$box/rec")"
  assert_contains "$r" 'action=wait dns_failures=1'
  now=$((now + DEGRADED_GRACE))   # age past the degraded dwell window
  state_machine_step degraded "$now" >"$box/rec"
  r="$(cat "$box/rec")"
  assert_contains "$r" 'action=WOULD_RESTART'

  # Backoff ladder 0,30,60,120,300,600 then the 900s cap (15 min); the NEXT
  # due attempt after MAX_RESTART_ATTEMPTS opens the circuit instead.
  # shellcheck disable=SC2034  # seeds for state_machine_step's globals
  current_state=unknown degraded_count=0 restart_attempts=0
  # shellcheck disable=SC2034  # seeds for state_machine_step's globals
  next_attempt=0 circuit_until=0 healthy_count=0
  bad_since=$((now - 10000))   # pre-age: settle/reconnect graces long elapsed
  expected=(0 30 60 120 300 600 900)
  for i in 1 2 3 4 5 6 7; do
    now=$((now + 10000))
    state_machine_step dead "$now" >"$box/rec"
    r="$(cat "$box/rec")"
    case "$r" in
      *action=WOULD_RESTART*) ;;
      *) fail "attempt $i did not request a restart: $r" ;;
    esac
    delay="${r##*next_delay=}"
    [ "$delay" = "${expected[$((i - 1))]}" ] \
      || fail "backoff for attempt $i: got '$delay', want '${expected[$((i - 1))]}"
  done
  now=$((now + 10000))
  state_machine_step dead "$now" >"$box/rec"
  r="$(cat "$box/rec")"
  case "$r" in
    *action=notify*retry_at=*) : ;;
    *) fail "attempt beyond MAX_RESTART_ATTEMPTS must open the circuit: $r" ;;
  esac
  # The breaker state survives persistence (atomic file, validated fields).
  save_monitor_state || fail 'save_monitor_state failed'
  grep -q '^current_state=circuit_open$' "$MONITOR_STATE_FILE" \
    || fail 'circuit state not persisted'
  grep -Eq '^circuit_until=[0-9]+$' "$MONITOR_STATE_FILE" \
    || fail 'circuit_until not persisted numerically'

  # Corrupt state resets conservatively: defaults, no shell evaluation, and
  # load REPORTS the corruption to its caller.
  # shellcheck disable=SC2016  # literal '$(...)' is the attack payload here
  printf 'current_state=circuit_open\nbad_since=$(touch /tmp/pwned)\n' >"$MONITOR_STATE_FILE"
  if load_monitor_state; then fail 'corrupt state file was accepted'; fi
  [ "$current_state" = unknown ] && [ "$bad_since" = 0 ] \
    || fail 'corrupt state did not reset conservatively'
  [ ! -e /tmp/pwned ] || { rm -f /tmp/pwned; fail 'state content was evaluated'; }
}

# End-to-end --once against sandbox fixtures: a dead tunnel with NO intent is
# left alone (idle); with intent + DRY_RUN it logs the exact would-be commands
# WITHOUT ever invoking sudo, and persists its counters atomically.
test_monitor_once_dead_fixture_dry_run() {
  local box out
  box="$(new_sandbox monitor-once)"
  export INTERVAL=20 RECONNECT_GRACE=0 NETWORK_SETTLE_GRACE=0 \
    DEGRADED_THRESHOLD=2 DEGRADED_GRACE=0 MAX_RESTART_ATTEMPTS=5 \
    AUCKLAND_VPN_DRY_RUN=1
  source_cli "$box"
  configure_generated_helper "$box"
  # Sentinel sudo: ANY invocation records itself and fails — dry-run must
  # never reach it.
  cat >"$box/bin/sudo" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$box/SUDO_CALLED"
exit 1
STUB
  chmod +x "$box/bin/sudo"
  export PATH="$box/bin:$PATH"

  # Fixture: pidfile exists but names nothing running -> observation=dead.
  : >"$PID_FILE"

  # No intent yet: the tunnel is NOT wanted up — observe, never heal.
  out="$(cmd_monitor --once 2>&1)" || fail "monitor --once (idle) failed: $out"
  assert_contains "$out" 'observation=dead'
  assert_contains "$out" 'state=idle action=none reason=intent-down'
  [ ! -e "$box/SUDO_CALLED" ] || fail 'idle pass invoked sudo'

  # Mark wanted-up (as 'auckland-vpn start' does): now the dead tunnel is due
  # for healing, which dry-run turns into logged would-be actions.
  touch "$STATE_DIR/monitor.enabled"
  out="$(cmd_monitor --once 2>&1)" || fail "monitor --once (heal) failed: $out"
  assert_contains "$out" 'observation=dead'
  assert_contains "$out" 'action=WOULD_RESTART'
  assert_contains "$out" "[dry-run] would run: sudo -n $HELPER_BIN stop"
  assert_contains "$out" "[dry-run] would run: sudo -n $HELPER_BIN start"
  [ ! -e "$box/SUDO_CALLED" ] || fail 'dry-run attempted sudo'
  # Counters persisted atomically: private mode, validated numeric content.
  [ "$(stat -f '%Lp' "$MONITOR_STATE_FILE")" = '600' ] \
    || fail "monitor-state not mode 600: $(stat -f '%Lp' "$MONITOR_STATE_FILE")"
  grep -q '^restart_attempts=1$' "$MONITOR_STATE_FILE" \
    || fail "restart attempt counter not persisted: $(cat "$MONITOR_STATE_FILE")"
}

# doctor gains informational monitor lines: running? and last recorded state?
test_doctor_reports_monitor_status() {
  local box out
  box="$(new_sandbox monitor-doctor)"
  source_cli "$box"
  configure_generated_helper "$box"
  out="$(cmd_doctor 2>&1 || true)"
  assert_contains "$out" 'INFO monitor not running'
  assert_contains "$out" 'INFO no monitor state recorded yet'
  printf 'current_state=degraded\nbad_since=0\ndegraded_count=1\nrestart_attempts=0\nnext_attempt=0\ncircuit_until=0\nhealthy_count=0\n' \
    >"$STATE_DIR/monitor-state"
  chmod 600 "$STATE_DIR/monitor-state"
  out="$(cmd_doctor 2>&1 || true)"
  assert_contains "$out" 'INFO monitor last recorded state: degraded'
}

# diagnose (issue #15) classifies failure classes from sandbox log fixtures.
test_diagnose_failure_classes() {
  local box out status
  box="$(new_sandbox diagnose)"
  source_cli "$box"
  LOG_FILE="$box/vpn.log"

  # No log at all: diagnose says so and exits non-zero (nothing to analyse).
  out="$(cmd_diagnose 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'diagnose without any log should exit non-zero'
  assert_contains "$out" 'No log file yet'

  printf '==== auckland-vpn start now ====\nInvalid credentials; try again.\n' >"$LOG_FILE"
  out="$(cmd_diagnose 2>&1)"
  assert_contains "$out" 'Refresh BOTH together'
  assert_contains "$out" 'REALM:     WARNING'

  printf "%s\nGot login realm 'client'\nConnected as 10.1.2.3\n%s\n%s\n" \
    '==== auckland-vpn start later ====' \
    'WARNING: Got split-DNS domains (not yet implemented)' \
    'Established DTLS connection (v1)' >"$LOG_FILE"
  out="$(cmd_diagnose 2>&1)"
  assert_contains "$out" "ok — \"Got login realm 'client'\" present"
  assert_contains "$out" 'does NOT implement'
  assert_contains "$out" 'TRANSPORT: DTLS established.'
}

# Issue #16: the two consult-approved WRAPPER-ONLY seams
# (docs/consults/test-architecture.md). AUCKLAND_VPN_HELPER_BIN /
# AUCKLAND_VPN_SUDO_BIN redirect which helper the wrapper asks sudo to run,
# and which sudo binary asks — honored only for an unprivileged caller. The
# generated PRIVILEGED helper must contain ZERO environment switches: no
# 'AUCKLAND_VPN' string at all (a behaviour switch inherited across sudo
# would be a second, less-defended root execution path).
test_wrapper_seams_are_wrapper_only() {
  local box helper overridden defaulted
  box="$(new_sandbox wrapper-seams)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  helper="$(generate_helper)"
  assert_not_contains "$helper" 'AUCKLAND_VPN' || return 1

  # The overrides are honoured when set...
  overridden="$(VPN_USER='' \
    AUCKLAND_VPN_HELPER_BIN="$box/fake-helper" AUCKLAND_VPN_SUDO_BIN="$box/fake-sudo" \
    bash -c 'source "$1"; printf "%s|%s" "$HELPER_BIN" "$SUDO_BIN"' _ "$CLI")"
  [ "$overridden" = "$box/fake-helper|$box/fake-sudo" ] \
    || { fail "seams not honoured when set: $overridden"; return 1; }
  # ...and inert when unset: production defaults.
  defaulted="$(VPN_USER='' bash -c 'source "$1"; printf "%s|%s" "$HELPER_BIN" "$SUDO_BIN"' _ "$CLI")"
  [ "$defaulted" = "/private/etc/auckland-vpn/helper|sudo" ] \
    || { fail "unexpected seam defaults: $defaulted"; return 1; }
}

# Issue #16 promotion smoke: tests/ is the single suite location (no
# prototype-suite copy, no symlink), directly executable, and CI runs exactly
# this script on macOS.
test_tests_dir_promoted_and_ci_runnable() {
  local suite="$TEST_DIR/run-tests.sh" wf="$ROOT/.github/workflows/tests.yml"
  [ -x "$suite" ] || { fail 'tests/run-tests.sh must be executable (CI invokes it directly)'; return 1; }
  head -n 1 "$suite" | grep -q '^#!/usr/bin/env bash$' \
    || { fail 'suite lost its bash shebang'; return 1; }
  bash -n "$suite" || return 1
  # Tripwire: references to the old prototype-suite location must be gone.
  ! grep -q 'prototypes[/]' "$suite" \
    || { fail 'stale prototype-suite path left behind'; return 1; }
  # Consult-mandated security greps must remain part of the static lints.
  grep -qF 'mktemp -d' "$suite" \
    || { fail 'static lint lost the mktemp -d /tmp grep'; return 1; }
  grep -qF 'pkill' "$suite" \
    || { fail 'static lint lost the unscoped-pkill grep'; return 1; }
  [ -f "$wf" ] || { fail '.github/workflows/tests.yml missing'; return 1; }
  grep -qF 'macos-latest' "$wf" \
    || { fail 'CI must run on macOS (BSD stat -f, macOS commands)'; return 1; }
  grep -qF 'tests/run-tests.sh' "$wf" \
    || { fail 'CI must invoke tests/run-tests.sh'; return 1; }
}

run_test() {
  local name="$1"
  if ( "$name" ); then
    printf 'ok - %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf 'not ok - %s\n' "$name"
    FAILED=$((FAILED + 1))
  fi
}

tests=(
  test_static_wrapper
  test_static_generated_helper
  test_config_rejects_shell_code
  test_config_rejects_conflicting_users
  test_attempt_log_scopes_latest_banner
  test_tunnel_ip_from_log
  test_privileged_command_contract
  test_start_success_with_stub_openconnect
  test_start_auth_failure_with_stub_openconnect
  test_helper_two_record_stdin_and_token_file
  test_concurrent_start_refused_by_lock
  test_sigterm_mid_operation_exits_cleanly
  test_stale_lock_takeover
  test_installer_takes_paths_as_parameters
  test_stop_timeout_reports_honestly_without_sigkill
  test_monitor_state_machine_transitions
  test_monitor_once_dead_fixture_dry_run
  test_doctor_reports_monitor_status
  test_diagnose_failure_classes
  test_wrapper_seams_are_wrapper_only
  test_tests_dir_promoted_and_ci_runnable
)

for test_name in "${tests[@]}"; do run_test "$test_name"; done
printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
