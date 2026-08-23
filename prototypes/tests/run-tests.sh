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
  local path="$1"
  cat >"$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--help" ]; then
  echo 'usage: openconnect --pid-file=FILE'
  exit 0
fi
if [ "${1:-}" = "--stub-daemon" ]; then
  trap 'exit 0' TERM INT
  while :; do sleep 1; done
fi
printf '%s\n' "$@" >"$STUB_RECORD.argv"
IFS= read -r password || true
printf '%s\n' "$password" >"$STUB_RECORD.stdin"
if [ "${STUB_OC_MODE:-success}" = "auth-fail" ]; then
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
if [ "${1:-}" = "-n" ]; then shift; fi
exec "$@"
STUB
  chmod +x "$path"
}

configure_generated_helper() {
  local box="$1"
  OPENCONNECT_BIN="$box/bin/openconnect"
  SCRIPT_PATH="$box/bin/vpnc-script"
  HELPER_DIR="$box/helper-dir"
  HELPER_BIN="$HELPER_DIR/helper"
  PID_FILE="$HELPER_DIR/vpn.pid"
  STATE_DIR="$box/state/auckland-vpn"
  LOG_FILE="$STATE_DIR/auckland-vpn.log"
  CONFIG_DIR="$box/home/.config/auckland-vpn"
  SECRET_FILE="$CONFIG_DIR/totp-secret"
  PASSWORD_FILE="$CONFIG_DIR/vpn-password"
  VPN_USER="student@example.test"
  mkdir -p "$HELPER_DIR" "$STATE_DIR" "$CONFIG_DIR"
  printf '#!/bin/sh\n' >"$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
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
  local box helper
  box="$(new_sandbox static-helper)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  helper="$HELPER_BIN"
  bash -n "$helper" || return
  shellcheck "$helper" || return
  ! grep -nE 'mktemp -d[[:space:]]+/tmp|(^|[[:space:]])pkill([[:space:]]|$)' "$helper" \
    || fail 'unsafe construct found in generated helper'
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
  expected="$(whoami) ALL=(root) NOPASSWD: $HELPER_BIN start, $HELPER_BIN stop"
  [ "$rule" = "$expected" ] || fail 'sudoers contract changed'
  assert_not_contains "$rule" "$OPENCONNECT_BIN"
  assert_not_contains "$rule" 'pkill'
}

test_start_success_with_stub_openconnect() {
  local box output stop_output args pid
  box="$(new_sandbox integration-success)"
  make_openconnect_stub "$box/bin/openconnect"
  make_fake_sudo "$box/bin/sudo"
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH" STUB_RECORD="$box/openconnect"
  output="$(cmd_start 2>&1)" || fail "start unexpectedly failed: $output"
  assert_contains "$output" 'Tunnel IP: 10.20.30.40'
  args="$(cat "$STUB_RECORD.argv")"
  assert_contains "$args" '--protocol=fortinet'
  assert_contains "$args" '--passwd-on-stdin'
  assert_contains "$args" "--pid-file=$PID_FILE"
  assert_contains "$args" 'connectvpn.auckland.ac.nz/client'
  [ "$(cat "$STUB_RECORD.stdin")" = 'correct horse battery staple' ] \
    || fail 'password was not re-fed to openconnect stdin'
  pid="$(cat "$PID_FILE")"
  stop_output="$(cmd_stop 2>&1)" || fail "stop unexpectedly failed: $stop_output"
  assert_contains "$stop_output" 'Disconnected.'
  [ ! -e "$PID_FILE" ] || fail 'stop left the pidfile behind'
  ! ps -p "$pid" >/dev/null 2>&1 || fail 'stop left the stub process running'
}

test_start_auth_failure_with_stub_openconnect() {
  local box output status
  box="$(new_sandbox integration-auth-fail)"
  make_openconnect_stub "$box/bin/openconnect"
  make_fake_sudo "$box/bin/sudo"
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH" STUB_RECORD="$box/openconnect" STUB_OC_MODE=auth-fail
  output="$(cmd_start 2>&1)"
  status=$?
  unset STUB_OC_MODE
  [ "$status" -ne 0 ] || fail 'authentication failure reported success'
  assert_contains "$output" 'Invalid password; authentication failed'
  assert_contains "$output" 'Connection failed. Full log'
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
)

for test_name in "${tests[@]}"; do run_test "$test_name"; done
printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
