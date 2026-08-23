#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../.." && pwd)"
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
if [ "${1:-}" = "--stub-daemon" ]; then
  trap 'exit 0' TERM INT
  while :; do sleep 1; done
fi
printf '%s\n' "$@" >"$recdir/stub.argv"
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
  printf 'TESTTOTSECRET\n' >"$SECRET_FILE"
  printf 'correct horse battery staple\n' >"$PASSWORD_FILE"
  generate_helper >"$HELPER_BIN"
  chmod +x "$HELPER_BIN"
}

test_static_wrapper() {
  command -v shellcheck >/dev/null || fail 'shellcheck is required'
  bash -n "$CLI" || return
  shellcheck "$CLI" || return
  ! grep -nE 'mktemp -d[[:space:]]+/tmp|sudo[[:space:]]+pkill[[:space:]]+(-[A-Za-z]*[[:space:]]+)*openconnect' "$CLI" \
    || fail 'unsafe temp directory or unscoped pkill found'
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
  for util in stat readlink dirname ps rm date chmod chown mktemp sleep basename cat env; do
    hit="$(grep -nE "(^|[^/A-Za-z0-9_])${util}([[:space:]]|;|\)|\$)" "$helper" \
      | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    [ -z "$hit" ] || fail "unqualified '$util' invocation in helper: $hit"
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
  args="$(cat "$box/bin/stub.argv")"
  assert_contains "$args" '--protocol=fortinet'
  assert_contains "$args" '--passwd-on-stdin'
  assert_contains "$args" "--pid-file=$PID_FILE"
  assert_contains "$args" 'connectvpn.auckland.ac.nz/client'
  [ "$(cat "$box/bin/stub.stdin")" = 'correct horse battery staple' ] \
    || fail 'password was not re-fed to openconnect stdin'
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
  [ ! -e "$PID_FILE" ] || fail 'stop left the pidfile behind'
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

  # A missing second record must fail loudly, before any launch (run FIRST:
  # a prior successful start leaves a pidfile that is not root-owned in this
  # unprivileged sandbox, which the helper rightly refuses).
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
)

for test_name in "${tests[@]}"; do run_test "$test_name"; done
printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
