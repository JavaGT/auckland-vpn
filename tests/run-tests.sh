#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
CLI="$ROOT/auckland-vpn"
TMP_ROOT="$TEST_DIR/.tmp.$$"
PASSED=0
FAILED=0
failed_names=()

mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Record failures on disk as well as returning 1: run_test scores a test on
# its subshell's FINAL exit status, so a `cmd || fail` chain would otherwise
# swallow a mid-test failure whenever a later command exits 0. A marker file
# crosses the subshell boundary; `exit 1` here would not (it would also fire
# the main shell's TMP_ROOT-cleanup EXIT trap and break later tests).
fail() {
  printf '    %s\n' "$*" >&2
  : > "$TMP_ROOT/.test-failed"
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
  # Faithful to the real binary, which exits 1 after help (#83): a stub
  # exiting 0 hides pipefail poisoning of the --pid-file capability probe.
  exit 1
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

test_config_rejects_internal_whitespace() {
  local box output status
  box="$(new_sandbox config-whitespace)"
  mkdir -p "$box/home/.config/auckland-vpn"
  printf 'VPN_USER=alice bob\n' >"$box/home/.config/auckland-vpn/config"
  output="$(HOME="$box/home" XDG_STATE_HOME="$box/state" VPN_USER='' bash -c 'source "$1"' _ "$CLI" 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'username with internal space was accepted'
  assert_contains "$output" 'unsupported characters'
}

test_env_username_rejected() {
  local box output status
  box="$(new_sandbox env-username)"
  output="$(HOME="$box/home" XDG_STATE_HOME="$box/state" VPN_USER='alice bob' bash -c 'source "$1"' _ "$CLI" 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'invalid env username was accepted'
  assert_contains "$output" 'unsupported characters'
}

test_setup_prompt_rejects_invalid_username() {
  local box output status
  box="$(new_sandbox setup-username)"
  output="$(HOME="$box/home" XDG_STATE_HOME="$box/state" VPN_USER='' \
    bash -c 'source "$1"; printf "alice bob\n" | cmd_setup' _ "$CLI" 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'setup accepted an invalid username'
  assert_contains "$output" 'unsupported username'
  [ ! -e "$box/home/.config/auckland-vpn/config" ] || fail 'invalid username was saved to the config file'
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

test_helper_bakes_pid_support_despite_help_exit_1() {
  # Real openconnect exits 1 after printing --help (origin 2b9e90f, #83);
  # under pipefail the probe must still report support, or setup aborts and
  # setup-sudo bakes OC_HAS_PID_FILE=0 into the helper.
  local box helper
  box="$(new_sandbox pidfile-probe)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  helper="$(generate_helper)"
  assert_contains "$helper" 'OC_HAS_PID_FILE=1'
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

# Stale operation locks fail closed to avoid concurrent replacement-lock races.
test_stale_lock_refusal_preserves_marker() {
  local box out status dead_pid
  box="$(new_sandbox stale-lock)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH"
  export SUDO_UID="$(id -u)" SUDO_GID="$(id -g)"

  # A dead holder is reported; its lock and marker stay intact.
  true & dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  mkdir "$HELPER_DIR/operation.lock"
  printf '%s\n' "$dead_pid" >"$HELPER_DIR/operation.lock/pid"
  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'start reclaimed a dead-holder lock automatically'
  assert_contains "$out" 'names dead pid'
  [ -f "$HELPER_DIR/operation.lock/pid" ] || fail 'dead-holder marker was removed'
  [ "$(cat "$HELPER_DIR/operation.lock/pid")" = "$dead_pid" ] || fail 'dead-holder marker changed'
  rm -f "$HELPER_DIR/operation.lock/pid"
  rmdir "$HELPER_DIR/operation.lock"

  # Scenario 2: EMPTY marker (an owner may sit in its mkdir→write-pid
  # window): after a short grace, refuse and preserve the empty marker.
  mkdir "$HELPER_DIR/operation.lock"
  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'start reclaimed an empty lock automatically'
  assert_contains "$out" 'cannot acquire operation lock'
  [ -d "$HELPER_DIR/operation.lock" ] || fail 'empty lock directory was removed'
  [ ! -s "$HELPER_DIR/operation.lock/pid" ] || fail 'empty lock marker changed'
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

# doctor warns (advisory WARN, never a FIX) on world-writable PATH ancestors
# and reports a clean PATH. PATH is pinned because the check reads the live
# environment — the suite must not depend on this machine's real PATH state
# (issue #35 hermeticity).
test_doctor_warns_on_writable_path_entries() {
  local box out
  box="$(new_sandbox doctor-path)"
  source_cli "$box"
  configure_generated_helper "$box"
  local base="/usr/bin:/bin" safe="$box/path-safe/bin" evil="$box/path-evil/bin"
  mkdir -p "$safe" "$evil"
  chmod 755 "$box/path-safe" "$box/path-evil"
  # world-writable ancestor of a PATH entry -> WARN, and no OK line
  chmod 777 "$box/path-evil"
  PATH="$base:$evil"
  out="$(cmd_doctor 2>&1 || true)"
  assert_contains "$out" 'world-writable component'
  assert_not_contains "$out" 'OK   PATH hygiene'
  # repairing the ancestor clears the warning
  chmod 755 "$box/path-evil"
  PATH="$base:$safe:$evil"
  out="$(cmd_doctor 2>&1 || true)"
  assert_contains "$out" 'OK   PATH hygiene'
  # an empty PATH entry (means the current directory) is warned about too
  PATH="$base:"
  out="$(cmd_doctor 2>&1 || true)"
  assert_contains "$out" 'empty entry (means the current directory)'
  # Apple's SIP-protected Cryptexes dir is root:wheel 777 but unwritable even
  # to root — the one inert ancestor must NOT warn (review of 9f5aefc). The
  # sandbox cannot create /System paths, so exercise the helper directly.
  path_hygiene_sip_exempt "/System/Volumes/Preboot/Cryptexes" "0:0" \
    || fail 'exempt: Cryptexes itself, root:wheel, should be skipped'
  path_hygiene_sip_exempt "/System/Volumes/Preboot/Cryptexes/App" "0:0" \
    || fail 'exempt: under-Cryptexes root:wheel should be skipped'
  path_hygiene_sip_exempt "/Users/someone/.local" "501:20" \
    && fail 'exempt: user-owned world-writable dir must not be skipped'
  path_hygiene_sip_exempt "/System/Volumes/Preboot/Cryptexes" "501:20" \
    && fail 'exempt: non-root-owned Cryptexes must not be skipped'
  path_hygiene_sip_exempt "/tmp/evil/System/Volumes/Preboot/Cryptexes" "0:0" \
    && fail 'exempt: lookalike path outside /System must not be skipped'
  # a PATH entry reached through a ../-spelled symlink reports the REAL
  # normalised path, not the ..-littered spelling (review N3)
  mkdir -p "$box/sub" "$box/target777/bin"
  chmod 777 "$box/target777"
  ln -s "../target777/bin" "$box/sub/entry"
  PATH="$base:$box/sub/entry"
  out="$(cmd_doctor 2>&1 || true)"
  assert_contains "$out" "world-writable component: $box/target777"
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

# Sol hardening wave (2026-10-03): setup-sudo must refuse an
# environment-overridden helper destination before generating anything or
# touching sudo — baking the AUCKLAND_VPN_HELPER_BIN seam into the persistent
# root NOPASSWD grant would authorise an attacker-chosen binary as root.
test_setup_sudo_rejects_helper_override() {
  local box out status
  box="$(new_sandbox setup-sudo-override)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  # Sentinel sudo: ANY invocation records itself — refusal must precede it.
  cat >"$box/bin/sudo" <<STUB
#!/usr/bin/env bash
printf 'CALLED\n' >"$box/SUDO_CALLED"
exit 0
STUB
  chmod +x "$box/bin/sudo"
  export PATH="$box/bin:$PATH"
  out="$(AUCKLAND_VPN_HELPER_BIN="$box/evil-helper" cmd_setup_sudo 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'setup-sudo accepted an overridden helper path'
  assert_contains "$out" 'setup-sudo requires the canonical helper path'
  [ ! -e "$box/SUDO_CALLED" ] || fail 'refused setup-sudo still invoked sudo'
}

# Sol hardening wave: the helper's trust walk must validate the ancestors
# holding a symlink, not just the resolved target — a writable directory
# containing the link could otherwise swap the binary under root.
test_helper_rejects_writable_symlink_ancestor() {
  local box out status
  box="$(new_sandbox helper-symlink)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH"
  export SUDO_UID="$(id -u)" SUDO_GID="$(id -g)"
  mkdir -p "$box/linkdir"
  ln -s "$box/bin/openconnect" "$box/linkdir/oc-link"
  chmod 777 "$box/linkdir"
  OPENCONNECT_BIN="$box/linkdir/oc-link"
  generate_helper >"$HELPER_BIN"
  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'helper start through a writable link-holder was not refused'
  assert_contains "$out" 'not root-trusted'
  [ "$(pgrep -f "$box/bin/openconnect" | wc -l | tr -d ' ')" = "0" ] \
    || fail 'refused start still launched openconnect'
  # The same target through a trustworthy holder still starts.
  chmod 755 "$box/linkdir"
  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)" \
    || fail "safe link chain refused: $out"
  env -i PATH=/usr/bin:/bin SUDO_UID="$(id -u)" SUDO_GID="$(id -g)" \
    "$HELPER_BIN" stop >/dev/null 2>&1 || true
}

# Sol hostile re-review: an intermediate ancestor symlink must not launder a
# writable holder — safe/alias -> writable-holder/target passes the literal
# ancestors (leaf, bin, alias, safe) while the writable holder only appears
# on the RESOLVED target chain. The trust walk must refuse it.
test_helper_rejects_writable_symlink_target_ancestor() {
  local box out status
  box="$(new_sandbox helper-symlink-ancestor)"
  mkdir -p "$box/writable-holder/target/bin"
  make_openconnect_stub "$box/writable-holder/target/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  export SUDO_UID="$(id -u)" SUDO_GID="$(id -g)"
  mkdir -p "$box/safe"
  ln -s "$box/writable-holder/target" "$box/safe/alias"
  chmod 777 "$box/writable-holder"
  OPENCONNECT_BIN="$box/safe/alias/bin/openconnect"
  generate_helper >"$HELPER_BIN"
  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'helper start through a writable symlinked ancestor was not refused'
  assert_contains "$out" 'not root-trusted'
  [ "$(pgrep -f "$box/safe/alias" | wc -l | tr -d ' ')" = "0" ] \
    || fail 'refused start still launched openconnect'
  # Repairing the holder admits the same chain: fail-closed, not fail-broken.
  chmod 755 "$box/writable-holder"
  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)" \
    || fail "safe symlinked-ancestor chain refused: $out"
  env -i PATH=/usr/bin:/bin SUDO_UID="$(id -u)" SUDO_GID="$(id -g)" \
    "$HELPER_BIN" stop >/dev/null 2>&1 || true
}

# Sol hostile re-review: cyclic or dangling symlinks on the trusted path must
# fail closed immediately (hop budget / existence gate), never hang root or
# resolve to something launchable.
test_helper_trust_walk_cycle_fails_closed() {
  local box out status
  box="$(new_sandbox helper-symlink-cycle)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  export SUDO_UID="$(id -u)" SUDO_GID="$(id -g)"
  mkdir -p "$box/loop"
  ln -s a "$box/loop/b"
  ln -s b "$box/loop/a"
  OPENCONNECT_BIN="$box/loop/a/bin/openconnect"
  generate_helper >"$HELPER_BIN"
  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'cyclic symlink chain was accepted'
  assert_contains "$out" 'not root-trusted'
  # Dangling leaf link: same fail-closed refusal.
  ln -s "$box/does-not-exist" "$box/loop/dangling"
  OPENCONNECT_BIN="$box/loop/dangling"
  generate_helper >"$HELPER_BIN"
  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'dangling symlink was accepted'
  assert_contains "$out" 'not root-trusted'
}

# Sol hardening wave: doctor's PATH walk has the same link-holder shape —
# it must report the writable directory holding the link, not just the
# (clean) target chain.
test_doctor_checks_link_parent() {
  local box out
  box="$(new_sandbox doctor-linkparent)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  mkdir -p "$box/holder" "$box/real/bin"
  ln -s "$box/real/bin" "$box/holder/entry"
  chmod 777 "$box/holder"
  PATH="/usr/bin:/bin:$box/holder/entry"
  out="$(cmd_doctor 2>&1 || true)"
  assert_contains "$out" 'world-writable component'
  assert_contains "$out" "$box/holder"
  assert_not_contains "$out" 'OK   PATH hygiene'
}

# Sol hostile re-review: a CLEAN symlink object whose TARGET is world-writable
# must not read as OK — keying the walk's seen-set by pwd -P marked the link's
# target as validated before anything checked it.
test_doctor_warns_on_writable_symlink_target() {
  local box out
  box="$(new_sandbox doctor-linktarget)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  mkdir -p "$box/real"
  chmod 777 "$box/real"
  ln -s "$box/real" "$box/entry"   # clean link object -> world-writable target
  PATH="/usr/bin:/bin:$box/entry"
  out="$(cmd_doctor 2>&1 || true)"
  assert_contains "$out" 'world-writable component'
  assert_contains "$out" "$box/real"
  assert_not_contains "$out" 'OK   PATH hygiene'
  # Repairing the target clears the warning: the link itself stays clean.
  chmod 755 "$box/real"
  out="$(cmd_doctor 2>&1 || true)"
  assert_contains "$out" 'OK   PATH hygiene'
}

# Sol hardening wave: connected-marker checks must not SIGPIPE the attempt
# producer — with an attempt larger than the pipe buffer, the old
# `attempt_log | grep -q` pipeline failed the writer and misreported a
# connected tunnel as failed under pipefail. A previous attempt's marker
# alone must still not verify.
test_large_attempt_marker_is_pipefail_safe() {
  local box out daemon size
  box="$(new_sandbox sigpipe-attempt)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  {
    printf '==== auckland-vpn start now ====\n'
    awk 'BEGIN { for (i = 0; i < 3000; i++) print "padding log line", i, "0123456789abcdef" }'
    printf 'Connected as 10.9.9.9, using SSL\n'
  } >"$LOG_FILE"
  size="$(wc -c <"$LOG_FILE" | tr -d ' ')"
  [ "$size" -gt 65536 ] || fail "fixture did not exceed the pipe buffer ($size bytes)"
  # The daemon argv names openconnect AND our host: running_vpn_pid's
  # recorded-PID branch demands the server identity (recycled-PID guard).
  "$box/bin/openconnect" --stub-daemon "$VPN_SERVER" >/dev/null 2>&1 &
  daemon=$!
  printf '%s\n' "$daemon" >"$PID_FILE"
  verify_tunnel_started >/dev/null 2>&1 \
    || fail 'large current attempt with a connected marker did not verify'
  out="$(cmd_status 2>&1)"
  assert_contains "$out" 'Connected as'
  kill "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  {
    printf '==== auckland-vpn start old ====\nConnected as 10.0.0.1\n'
    printf '==== auckland-vpn start new ====\nStill connecting...\n'
  } >"$LOG_FILE"
  "$box/bin/openconnect" --stub-daemon "$VPN_SERVER" >/dev/null 2>&1 &
  daemon=$!
  printf '%s\n' "$daemon" >"$PID_FILE"
  out="$(cmd_status 2>&1)"
  assert_contains "$out" 'Connecting...'
  kill "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true

  # A stale PID plus a fresh connection marker is not proof of a live tunnel.
  printf '==== auckland-vpn start stale ===\nConnected as 10.9.9.9, using SSL\n' >"$LOG_FILE"
  printf '99999999\n' >"$PID_FILE"
  sleep() { :; }  # make the 30-poll negative path immediate
  if verify_tunnel_started >/dev/null 2>&1; then
    unset -f sleep
    fail 'startup verification accepted a connected marker with no live matching PID'
  fi
  unset -f sleep
}

# Sol hardening wave: doctor must probe sudo authorisation with the helper
# path and action as SEPARATE operands — the old single-string
# `sudo -n -l "helper start"` probe could never match a real sudoers rule,
# so healthy installs always reported FIX. Passwordlessness is claimed only
# when both detailed listings report no authentication requirement.
test_doctor_helper_authorization_contract() {
  local box out status
  box="$(new_sandbox doctor-authz)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  cat >"$box/bin/sudo" <<STUB
#!/usr/bin/env bash
printf '%s|' "\$@" >>"$box/SUDO_ARGV"
printf '\n' >>"$box/SUDO_ARGV"
if [ "\$#" -eq 4 ] && [ "\$1" = "-n" ] && [ "\$2" = "-ll" ] && [ "\$3" = "$HELPER_BIN" ]; then
  case "\$4" in
    start|stop)
      if [ "\${DENY:-}" = "1" ]; then exit 1; fi
      printf 'User %s may run the following commands:\n    Options: !authenticate\n    (root) %s %s\n' "\$(whoami)" "\$3" "\$4"
      exit 0
      ;;
  esac
fi
exit 1
STUB
  chmod +x "$box/bin/sudo"
  export PATH="$box/bin:$PATH"
  out="$(cmd_doctor 2>&1)"
  status=$?
  [ "$status" -eq 0 ] || fail "doctor failed on a permitted install: $out"
  assert_contains "$out" 'passwordless sudo allows it'
  grep -qF -- "-n|-ll|$HELPER_BIN|start" "$box/SUDO_ARGV" \
    || fail "doctor did not probe start with split operands: $(cat "$box/SUDO_ARGV")"
  grep -qF -- "-n|-ll|$HELPER_BIN|stop" "$box/SUDO_ARGV" \
    || fail "doctor did not probe stop with split operands: $(cat "$box/SUDO_ARGV")"
  out="$(DENY=1 cmd_doctor 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'doctor reported OK for a denied install'
  assert_contains "$out" 'sudoers does not allow it'
}

# Sol hardening wave: under the helper operation lock, a second sequential
# start while the recorded tunnel is still live must refuse — otherwise it
# truncates the pidfile and launches a second client beside the first.
test_helper_sequential_start_refused() {
  local box out status daemon_pid daemon_count
  box="$(new_sandbox helper-sequential)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  export PATH="$box/bin:$PATH"
  export SUDO_UID="$(id -u)" SUDO_GID="$(id -g)"
  printf '%s\n%s\n' pass tok | "$HELPER_BIN" start >/dev/null 2>&1 \
    || fail 'first helper start failed'
  daemon_pid="$(cat "$PID_FILE")"
  out="$(printf '%s\n%s\n' pass tok | "$HELPER_BIN" start 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'second sequential start was not refused'
  assert_contains "$out" 'already connected/starting'
  [ "$(cat "$PID_FILE")" = "$daemon_pid" ] \
    || fail 'refused start mutated the pidfile'
  daemon_count="$(pgrep -f "$box/bin/openconnect" | wc -l | tr -d ' ')"
  [ "$daemon_count" = "1" ] || fail "expected exactly 1 tunnel process, got $daemon_count"
  env -i PATH=/usr/bin:/bin SUDO_UID="$(id -u)" SUDO_GID="$(id -g)" \
    "$HELPER_BIN" stop >/dev/null 2>&1 || true
}

# Sol hostile re-review: running_vpn_pid's recorded-PID branch must demand
# OUR host in the process command line — a recycled PID holding some other
# server's openconnect client is not this tunnel (spawned via a script file
# so the harness's own argv can never match the scoped pgrep).
test_running_vpn_pid_requires_server_identity() {
  local box pid_foreign pid_suffix pid_ours
  box="$(new_sandbox vpn-pid-identity)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  "$box/bin/openconnect" --stub-daemon vpn.other.example/client >/dev/null 2>&1 &
  pid_foreign=$!
  printf '%s\n' "$pid_foreign" >"$PID_FILE"
  [ -z "$(running_vpn_pid || true)" ] \
    || fail 'running_vpn_pid accepted a foreign-server client as ours'
  kill "$pid_foreign" 2>/dev/null || true
  wait "$pid_foreign" 2>/dev/null || true
  "$box/bin/openconnect" --stub-daemon "${VPN_SERVER}-other" >/dev/null 2>&1 &
  pid_suffix=$!
  printf '%s\n' "$pid_suffix" >"$PID_FILE"
  [ -z "$(running_vpn_pid || true)" ] \
    || fail 'running_vpn_pid accepted a server name with a suffix'
  kill "$pid_suffix" 2>/dev/null || true
  wait "$pid_suffix" 2>/dev/null || true
  "$box/bin/openconnect" --stub-daemon "$VPN_SERVER" >/dev/null 2>&1 &
  pid_ours=$!
  printf '%s\n' "$pid_ours" >"$PID_FILE"
  [ "$(running_vpn_pid || true)" = "$pid_ours" ] \
    || fail "running_vpn_pid did not recognise our own recorded client: $(ps -p "$pid_ours" -o command= 2>/dev/null)"
  kill "$pid_foreign" "$pid_suffix" "$pid_ours" 2>/dev/null || true
  wait "$pid_foreign" 2>/dev/null || true
  wait "$pid_suffix" 2>/dev/null || true
  wait "$pid_ours" 2>/dev/null || true
  : >"$PID_FILE"
}

# Sol hostile re-review: a live FOREIGN-server openconnect recorded in the
# pidfile must not suppress the heal — the old already-running skip called
# running_vpn_pid's loose openconnect-only branch, so a recycled PID running
# another server's client blocked the legitimate Auckland restart forever.
test_heal_restarts_despite_foreign_server_client() {
  local box out status foreign
  box="$(new_sandbox heal-foreign-client)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  notify_user() { return 0; }
  monitor_network_ready() { return 0; }   # reach the launch phase
  verify_tunnel_started() { return 0; }   # this test asserts launch admission, not openconnect startup
  cat >"$box/bin/sudo" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$box/SUDO_CALLS"
exit 0
STUB
  chmod +x "$box/bin/sudo"
  export PATH="$box/bin:$PATH"
  touch "$STATE_DIR/monitor.enabled"   # intent up: a heal is wanted
  cat >"$box/spawn-foreign" <<'SPAWN'
#!/usr/bin/env bash
exec -a 'openconnect --protocol=fortinet vpn.other.example/client' sleep 30
SPAWN
  chmod +x "$box/spawn-foreign"
  "$box/spawn-foreign" >/dev/null 2>&1 &
  foreign=$!
  printf '%s\n' "$foreign" >"$PID_FILE"
  printf '==== auckland-vpn start now ====\nConnected as 10.9.9.9, using SSL\n' >"$LOG_FILE"
  out="$(monitor_heal 2>&1)"
  status=$?
  kill "$foreign" 2>/dev/null || true
  wait "$foreign" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "heal failed with a foreign client recorded: $out"
  case "$out" in
    *already*running*) fail 'heal skipped for a FOREIGN-server client: '"$out" ;;
  esac
  grep -qw start "$box/SUDO_CALLS" \
    || fail "foreign client suppressed the heal restart: $(cat "$box/SUDO_CALLS")"
  grep -q 'heal=recovered' "$MONITOR_LOG" \
    || fail "heal did not complete: $out"
}

# Sol hardening wave: a user stop that lands mid-heal (credential lookup or
# the stop/start gap) clears the intent file — the launch phase must
# recheck it immediately before starting, or the monitor resurrects a tunnel
# the user just killed.
test_stop_cancels_inflight_heal() {
  local box out status
  box="$(new_sandbox heal-cancel)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  monitor_network_ready() { return 0; }   # reach the launch phase
  cat >"$box/bin/sudo" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$box/SUDO_CALLS"
exit 0
STUB
  chmod +x "$box/bin/sudo"
  export PATH="$box/bin:$PATH"
  : >"$PID_FILE"   # nothing running: the heal stop phase is a no-op success
  rm -f "$STATE_DIR/monitor.enabled"   # ...but intent is down: stop won the race
  out="$(monitor_heal 2>&1)"
  status=$?
  [ "$status" -eq 0 ] || fail "cancelled heal did not exit 0: $out"
  assert_contains "$out" 'intent-down'
  grep -qw start "$box/SUDO_CALLS" \
    && fail "cancelled heal still issued a helper start: $(cat "$box/SUDO_CALLS")"
  grep -q 'heal=cancelled reason=intent-down' "$MONITOR_LOG" \
    || fail 'cancel was not logged'
}

# Sol hardening wave: cmd_stop must serialize with the final heal launch. Hold
# the fake helper at start after the monitor has acquired intent.lock, request
# a stop, and verify that stop cannot finish until the start completes. It
# then runs after that start and leaves intent down with no live tunnel.
test_stop_serializes_with_heal_launch() {
  local box out status healer stopper i
  box="$(new_sandbox heal-stop-serialization)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  monitor_network_ready() { return 0; }
  verify_tunnel_started() { return 0; }
  notify_user() { return 0; }
  cat >"$box/bin/sudo" <<STUB
#!/usr/bin/env bash
set -euo pipefail
export SUDO_UID="$(id -u)" SUDO_GID="$(id -g)"
if [ "\${1:-}" = "-n" ]; then shift; fi
action="\${2:-}"
printf '%s\n' "\$action" >>"$box/SUDO_ACTIONS"
if [ "\$action" = start ]; then
  : >"$box/START_ENTERED"
  while [ ! -e "$box/RELEASE_START" ]; do sleep 0.05; done
fi
exec "\$@"
STUB
  chmod +x "$box/bin/sudo"
  SUDO_BIN="$box/bin/sudo"
  export PATH="$box/bin:$PATH"
  touch "$MONITOR_ENABLED_FILE"

  ( monitor_heal >"$box/heal.out" 2>&1 ) &
  healer=$!
  for i in $(seq 1 100); do
    [ -e "$box/START_ENTERED" ] && break
    sleep 0.05
  done
  [ -e "$box/START_ENTERED" ] || {
    kill "$healer" 2>/dev/null || true
    fail 'heal never reached its controlled helper-start window'
    return 1
  }

  ( cmd_stop >"$box/stop.out" 2>&1 ) &
  stopper=$!
  sleep 0.25
  if ! kill -0 "$stopper" 2>/dev/null; then
    : >"$box/RELEASE_START"
    wait "$healer" 2>/dev/null || true
    wait "$stopper" 2>/dev/null || true
    fail 'cmd_stop returned while the heal start still held the intent lock'
    return 1
  fi

  : >"$box/RELEASE_START"
  wait "$healer" || { out="$(cat "$box/heal.out")"; fail "heal failed: $out"; }
  wait "$stopper" || { out="$(cat "$box/stop.out")"; fail "stop failed: $out"; }
  [ ! -e "$MONITOR_ENABLED_FILE" ] || fail 'stop left VPN intent enabled'
  [ -z "$(running_vpn_pid || true)" ] || fail 'tunnel remained live after serialized stop'
  [ "$(tr '\n' ' ' <"$box/SUDO_ACTIONS" | sed 's/[[:space:]]*$//')" = 'stop start stop' ] \
    || fail "expected heal-stop, heal-start, user-stop order; got: $(cat "$box/SUDO_ACTIONS")"
}

# A fresh install may not have created per-user state yet. `stop` is still an
# idempotent user command, so it must create that directory before acquiring
# the new lifecycle lock.
test_stop_creates_state_dir_before_lock() {
  local box out
  box="$(new_sandbox stop-without-state)"
  make_openconnect_stub "$box/bin/openconnect"
  source_cli "$box"
  configure_generated_helper "$box"
  rmdir "$STATE_DIR"
  out="$(cmd_stop 2>&1)" || fail "stop failed before state existed: $out"
  [ -d "$STATE_DIR" ] || fail 'stop did not create its state directory'
  assert_contains "$out" 'Not connected.'
}

# Automatic stale-lock removal has a two-reclaimer race: a contender can
# delete a live replacement lock after both observed the old dead PID. Fail
# closed and preserve the marker so recovery is deliberate and reviewable.
test_intent_lock_stale_marker_is_preserved() {
  local box out status
  box="$(new_sandbox intent-stale-lock)"
  source_cli "$box"
  configure_generated_helper "$box"
  mkdir "$INTENT_LOCK_DIR"
  printf '99999999\n' >"$INTENT_LOCK_DIR/pid"
  out="$(intent_lock_acquire 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || fail 'stale intent lock was silently reclaimed'
  assert_contains "$out" 'has a stale PID'
  [ "$(cat "$INTENT_LOCK_DIR/pid")" = '99999999' ] \
    || fail 'stale-lock refusal modified the existing marker'
}

# Sol hardening wave: an expired breaker must admit exactly one half-open
# probe — a further failure re-opens the circuit, while health clears it
# through the normal two-pass threshold.
test_monitor_circuit_half_open() {
  local box now r i
  box="$(new_sandbox circuit-halfopen)"
  export MAX_RESTART_ATTEMPTS=3 CIRCUIT_COOLDOWN=3600 BACKOFF_CAP=900 \
    NETWORK_SETTLE_GRACE=0 RECONNECT_GRACE=0 DEGRADED_GRACE=0 DEGRADED_THRESHOLD=2
  source_cli "$box"
  ensure_state_dir
  # shellcheck disable=SC2034  # seeds for state_machine_step's globals
  current_state=unknown bad_since=0 degraded_count=0 restart_attempts=0
  # shellcheck disable=SC2034  # seeds for state_machine_step's globals
  next_attempt=0 circuit_until=0 healthy_count=0
  now=1000000
  bad_since=$((now - 10000))   # pre-age: settle grace long elapsed
  for i in 1 2 3; do
    now=$((now + 10000))
    state_machine_step dead "$now" >"$box/rec"
    r="$(cat "$box/rec")"
    case "$r" in
      *action=WOULD_RESTART*) ;;
      *) fail "attempt $i did not request a restart: $r"; return 1 ;;
    esac
  done
  now=$((now + 10000))
  state_machine_step dead "$now" >"$box/rec"
  r="$(cat "$box/rec")"
  case "$r" in
    *state=circuit_open*action=notify*) ;;
    *) fail "exhaustion did not open the circuit: $r"; return 1 ;;
  esac
  # Inside the cool-down: open, with no action to execute.
  now=$((now + 100))
  state_machine_step dead "$now" >"$box/rec"
  r="$(cat "$box/rec")"
  case "$r" in
    *state=circuit_open*retry_at=*) ;;
    *) fail "cool-down did not hold the circuit open: $r"; return 1 ;;
  esac
  case "$r" in
    *action=*) fail "cool-down must emit no action: $r"; return 1 ;;
  esac
  # Past the cool-down: exactly one half-open probe restart...
  now=$((circuit_until + 1))
  state_machine_step dead "$now" >"$box/rec"
  r="$(cat "$box/rec")"
  case "$r" in
    *action=WOULD_RESTART*) ;;
    *) fail "expired circuit admitted no half-open probe: $r"; return 1 ;;
  esac
  # ...whose failure re-opens the circuit instead of granting a full budget.
  now=$((now + 10000))
  state_machine_step dead "$now" >"$box/rec"
  r="$(cat "$box/rec")"
  case "$r" in
    *state=circuit_open*action=notify*) ;;
    *) fail "failed probe did not reopen the circuit: $r"; return 1 ;;
  esac
  # And health after expiry clears the breaker through the normal threshold.
  now=$((circuit_until + 1))
  state_machine_step healthy "$now" >"$box/rec"
  state_machine_step healthy "$now" >"$box/rec"
  r="$(cat "$box/rec")"
  case "$r" in
    *state=healthy*) ;;
    *) fail "health did not clear the circuit: $r"; return 1 ;;
  esac
  [ "$circuit_until" -eq 0 ] || fail 'healthy recovery left circuit_until set'
}

# Sol hardening wave: offline passes must defer WITHOUT spending the retry
# budget or touching the helper; restored readiness admits an attempt that
# is charged exactly once.
test_monitor_network_deferral_preserves_budget() {
  local box now rec i sleeper
  box="$(new_sandbox network-deferral)"
  export MAX_RESTART_ATTEMPTS=5 CIRCUIT_COOLDOWN=3600 BACKOFF_CAP=900 \
    NETWORK_SETTLE_GRACE=0 RECONNECT_GRACE=0 DEGRADED_GRACE=0 DEGRADED_THRESHOLD=2
  source_cli "$box"
  configure_generated_helper "$box"
  notify_user() { return 0; }   # silent fixture: no desktop popups from heals
  monitor_network_ready() { return 1; }   # offline
  verify_tunnel_started() { return 0; }   # keep the ready-path assertion focused on admission
  cat >"$box/bin/sudo" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$box/SUDO_CALLS"
exit 0
STUB
  chmod +x "$box/bin/sudo"
  export PATH="$box/bin:$PATH"
  touch "$STATE_DIR/monitor.enabled"   # intent up: healing is wanted
  : >"$PID_FILE"                        # dead tunnel fixture
  # shellcheck disable=SC2034  # seeds for state_machine_step's globals
  current_state=unknown bad_since=0 degraded_count=0 restart_attempts=0
  # shellcheck disable=SC2034  # seeds for state_machine_step's globals
  next_attempt=0 circuit_until=0 healthy_count=0
  now="$(date +%s)"
  bad_since=$((now - 10000))   # pre-age: settle grace long elapsed
  # NOTE: monitor_act runs in the current shell (never $()), so the
  # budget refund it performs stays visible to the assertions below.
  for i in 1 2 3; do
    now=$((now + 10000))
    state_machine_step dead "$now" >"$box/rec"
    rec="$(cat "$box/rec")"
    case "$rec" in
      *action=WOULD_RESTART*) ;;
      *) fail "offline pass $i admitted no restart: $rec"; return 1 ;;
    esac
    monitor_act "$rec" || { fail "deferred act failed on pass $i"; return 1; }
  done
  [ "$restart_attempts" -eq 0 ] \
    || fail "offline deferral consumed the budget (attempts=$restart_attempts)"
  [ ! -e "$box/SUDO_CALLS" ] \
    || fail "deferred heal invoked sudo: $(cat "$box/SUDO_CALLS")"
  grep -q 'heal=deferred reason=network-not-ready' "$MONITOR_LOG" \
    || fail 'deferral was not logged'
  # Readiness restored: the next due attempt runs and is charged exactly once.
  monitor_network_ready() { return 0; }
  sleep 300 >/dev/null 2>&1 &
  sleeper=$!
  printf '%s\n' "$sleeper" >"$PID_FILE"
  printf '==== auckland-vpn start now ====\nConnected as 10.9.9.9, using SSL\n' >>"$LOG_FILE"
  now=$((now + 10000))
  state_machine_step dead "$now" >"$box/rec"
  rec="$(cat "$box/rec")"
  case "$rec" in
    *action=WOULD_RESTART*) ;;
    *) fail "ready pass admitted no restart: $rec"; kill "$sleeper" 2>/dev/null; return 1 ;;
  esac
  monitor_act "$rec" || { fail 'admitted heal failed'; kill "$sleeper" 2>/dev/null; return 1; }
  [ "$restart_attempts" -eq 1 ] \
    || fail "expected exactly 1 charged attempt, got $restart_attempts"
  grep -qw start "$box/SUDO_CALLS" \
    || fail "ready heal issued no helper start: $(cat "$box/SUDO_CALLS")"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
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
  local name="$1" status=0
  rm -f "$TMP_ROOT/.test-failed"
  ( "$name" ) || status=1
  # A recorded failure fails the test even if the subshell exited 0.
  [ -e "$TMP_ROOT/.test-failed" ] && status=1
  if [ "$status" -eq 0 ]; then
    printf 'ok - %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf 'not ok - %s\n' "$name"
    FAILED=$((FAILED + 1))
    failed_names+=("$name")
  fi
}

tests=(
  test_static_wrapper
  test_static_generated_helper
  test_config_rejects_shell_code
  test_config_rejects_conflicting_users
  test_config_rejects_internal_whitespace
  test_env_username_rejected
  test_setup_prompt_rejects_invalid_username
  test_attempt_log_scopes_latest_banner
  test_tunnel_ip_from_log
  test_privileged_command_contract
  test_helper_bakes_pid_support_despite_help_exit_1
  test_start_success_with_stub_openconnect
  test_start_auth_failure_with_stub_openconnect
  test_helper_two_record_stdin_and_token_file
  test_concurrent_start_refused_by_lock
  test_sigterm_mid_operation_exits_cleanly
  test_stale_lock_refusal_preserves_marker
  test_installer_takes_paths_as_parameters
  test_stop_timeout_reports_honestly_without_sigkill
  test_monitor_state_machine_transitions
  test_monitor_once_dead_fixture_dry_run
  test_doctor_reports_monitor_status
  test_doctor_warns_on_writable_path_entries
  test_diagnose_failure_classes
  test_wrapper_seams_are_wrapper_only
  test_setup_sudo_rejects_helper_override
  test_helper_rejects_writable_symlink_ancestor
  test_helper_rejects_writable_symlink_target_ancestor
  test_helper_trust_walk_cycle_fails_closed
  test_doctor_checks_link_parent
  test_doctor_warns_on_writable_symlink_target
  test_large_attempt_marker_is_pipefail_safe
  test_doctor_helper_authorization_contract
  test_helper_sequential_start_refused
  test_running_vpn_pid_requires_server_identity
  test_heal_restarts_despite_foreign_server_client
  test_stop_cancels_inflight_heal
  test_stop_serializes_with_heal_launch
  test_stop_creates_state_dir_before_lock
  test_intent_lock_stale_marker_is_preserved
  test_monitor_circuit_half_open
  test_monitor_network_deferral_preserves_budget
  test_tests_dir_promoted_and_ci_runnable
)

# Usage: tests/run-tests.sh [substring ...]
# No arguments runs the full suite (CI invokes it exactly this way).
# Substring arguments select a focused subset for quick iteration, e.g.
#   tests/run-tests.sh monitor          # every test matching "monitor"
#   tests/run-tests.sh config seams     # union of both matches
selected=()
for test_name in "${tests[@]}"; do
  if [ "$#" -gt 0 ]; then
    keep=0
    for pattern in "$@"; do
      case "$test_name" in *"$pattern"*) keep=1 ;; esac
    done
    [ "$keep" -eq 1 ] || continue
  fi
  selected+=("$test_name")
done

if [ "${#selected[@]}" -eq 0 ]; then
  printf 'no tests match any of: %s\n' "$*" >&2
  exit 1
fi

for test_name in "${selected[@]}"; do run_test "$test_name"; done
printf '\n%d passed, %d failed (%d of %d tests selected)\n' \
  "$PASSED" "$FAILED" "${#selected[@]}" "${#tests[@]}"
# Failure names repeat at the end so an agent/CI log tail shows what broke
# without scrolling through the whole run.
if [ "${#failed_names[@]}" -gt 0 ]; then
  printf 'failed:\n'
  printf '  - %s\n' "${failed_names[@]}"
fi
[ "$FAILED" -eq 0 ]
