# Reliability design for `auckland-vpn`

> **Status (2026-09-10):** the `monitor` command shipped **foreground-only** —
> LaunchAgent supervision was consciously not implemented (see README
> "Auto-heal monitor"). The state file is `monitor-state` (not `monitor.state`)
> in `~/.local/state/auckland-vpn/`. The `sudo -n` verification below is a
> one-shot check of the helper grant before enabling auto-heal; it does not
> license `sudo -n true` as a liveness probe, which AGENTS.md forbids.

## Decision

Add an opt-in `auckland-vpn monitor` foreground command and supervise it with a
per-user `launchd` LaunchAgent. The monitor polls every 20 seconds while the VPN
is desired, performs cheap process/interface/route checks on every pass, and
performs an end-to-end DNS check every 60 seconds. Polling is deliberately the
primary mechanism: it survives sleep, does not depend on private macOS event
APIs, and naturally observes both wake and network transitions.

The monitor runs in the logged-in user's context. It can read that user's
configuration and unlocked login Keychain, show notifications, and use the
existing passwordless sudoers commands:

```text
/private/etc/auckland-vpn/helper start
/private/etc/auckland-vpn/helper stop
```

No broader sudo rule and no root daemon are required. A restart is exactly
`helper stop`, followed by the existing wrapper's credential lookup and
`helper start`. The helper continues to own all privileged decisions and fixed
openconnect arguments.

Do not make `launchd` run `doctor` periodically. `doctor` checks installation
prerequisites, not tunnel liveness, and a one-shot job has nowhere cleanly to
keep hysteresis, backoff, desired state, or a circuit breaker.

## Operating model and user intent

Availability and intent are separate state:

- `desired=up`: the user has enabled monitoring or run `start` while monitoring
  is enabled. The monitor may heal the tunnel.
- `desired=down`: the user ran `stop` or disabled monitoring. A dead tunnel is
  expected and must not be restarted.

Store intent and monitor state in the existing private state directory:

```text
~/.local/state/auckland-vpn/monitor.enabled
~/.local/state/auckland-vpn/monitor.state
~/.local/state/auckland-vpn/monitor.lock/
~/.local/state/auckland-vpn/monitor.log
```

`monitor.enabled` should be an ordinary mode-600 file owned by the user.
Presence means desired up; absence means desired down. Integrating the feature
requires `start`/`restart` to leave intent up and an explicit `stop` to remove
it. The monitor's own stop-before-restart must call an internal operation that
does **not** clear intent. `monitor disable` clears intent and stops healing;
whether it also disconnects should be an explicit CLI choice, not implicit.

Use an atomic `mkdir monitor.lock` as the single-monitor lock. `flock` is not a
stock macOS command. Trap `EXIT HUP INT TERM` to remove a lock owned by the
current monitor, and treat a lock whose recorded PID is not alive as stale.

## Watchdog options on macOS 13-15

### Recommended: LaunchAgent plus foreground monitor

A LaunchAgent starts after GUI login, runs as the user, and supervises one
long-lived `auckland-vpn monitor` process. Use `KeepAlive` for process
supervision and `RunAtLoad`; the command itself remains inert when desired state
is down. On wake, the process resumes and its monotonic/wall-clock gap detection
causes an immediate check. If macOS killed it during sleep, `launchd` starts it
again.

Suggested plist properties:

```xml
<key>Label</key><string>nz.ac.auckland.vpn.monitor</string>
<key>ProgramArguments</key>
<array><string>/absolute/path/auckland-vpn</string><string>monitor</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>ProcessType</key><string>Background</string>
```

Use absolute paths. Do not put secrets in the plist or environment. A
LaunchAgent can normally query an unlocked login Keychain, but it cannot handle
an interactive Keychain approval dialog. Installation should perform one
foreground credential read so the user can approve access before relying on
unattended healing. Before enabling auto-heal, verify both exact sudo commands
with `sudo -n`; never fall back to an interactive sudo prompt in the monitor.

This does not reconnect before login, which is desirable: credentials belong to
the user session, notifications need that session, and pre-login VPN would
otherwise require a root daemon and a new secret-access design.

### `StartInterval` one-shot LaunchAgent

`StartInterval=30` is viable for a stateless check. `launchd` does not run
interval jobs while the machine sleeps; a missed interval is generally
coalesced into a run after wake rather than replayed. It also avoids a resident
shell. However, restart history and hysteresis still need files, every run pays
shell/config startup cost, and interval scheduling alone does not provide a
network-change event. This is acceptable as a simpler fallback, but inferior to
one supervised loop.

`WatchPaths` is not a network watcher. It observes filesystem paths and may
coalesce changes. Watching `/var/run/resolv.conf` or system configuration files
is an implementation accident, misses some scoped-DNS and reachability changes,
and can fire before configuration has settled. It should not drive healing.

### Sleep/wake hooks

- **SleepWatcher** works on current macOS as a Homebrew dependency and can run
  user wake hooks. It provides a prompt wake signal, but it is not stock macOS,
  does not solve ordinary network transitions, and hook ordering races with
  Wi-Fi/DHCP/DNS convergence. It is an optional accelerator only; the polling
  monitor still has to exist.
- **`pmset`** can display power state and schedule power events. It does not
  offer a supported arbitrary user sleep/wake callback facility. `pmset`
  custom wake scheduling is not a watchdog design.
- **IOPM power assertions** prevent or delay idle sleep. They are not wake
  callbacks, and preventing laptop sleep to preserve a VPN is the wrong power
  and reliability tradeoff.
- **Private `launchd`/loginwindow notification names and `/Library` sleep hook
  tricks** are unsupported and have varied across macOS releases. Do not use
  them.

The reliable wake detector is mundane: before sleeping the monitor records
`date +%s`; after `sleep 20`, a gap materially above the interval (for example,
greater than 45 seconds) means suspend or severe scheduling delay. Run a health
check immediately, but allow network-settle grace before healing.

### Network-change triggers

`SCNetworkReachability` and `SCDynamicStore` callbacks are the supported native
APIs. A small Swift/Objective-C process can subscribe to reachability and
`State:/Network/...` dynamic-store changes, but bash cannot register those
callbacks directly. `scutil -r host` is a point-in-time reachability query, not
a general event subscription. `scutil -w key` waits on a particular dynamic
store key and is awkward for multiple changing services; it is not a complete
network monitor.

Do not scrape `log stream` for `configd` messages or use private notify keys.
Those strings are unstable and logs may be delayed or rate-limited.

For a hobbyist-maintainable bash tool, 20-second polling is the right tradeoff.
If recovery latency later proves unacceptable, add a tiny compiled
`SCDynamicStore` event helper that merely wakes the same health state machine.
It should not own credentials or privileged operations. Polling remains the
fallback and correctness mechanism.

## Health model

### Required probe configuration

Process existence cannot prove service. A strong check requires one stable
University internal hostname that:

- resolves only when University VPN DNS is working;
- has at least one expected private address or expected DNS suffix; and
- routes through the VPN.

Call it `VPN_HEALTH_HOST`. If possible also configure a stable internal IP as
`VPN_HEALTH_IP`; this separates routing failure from DNS failure. Do not use the
public VPN gateway as the routed-through-tunnel probe: the outer openconnect
connection must route to that gateway over Wi-Fi/Ethernet, not recursively over
`utun`.

If no stable probe is configured, report `unknown`/`basic-up` and only auto-heal
high-confidence process death. Calling that state healthy would be dishonest.

### Signals and exact macOS/BSD checks

All checks below are unprivileged and available on stock macOS. `dig` is shipped
on macOS 13-15; use `/usr/bin/dig` explicitly.

**1. Recorded process belongs to this VPN**

```bash
pid=$(cat /private/etc/auckland-vpn/vpn.pid 2>/dev/null) || pid=
case "$pid" in ''|*[!0-9]*) pid= ;; esac
command=$(ps -p "$pid" -o command= 2>/dev/null) || command=
case "$command" in *openconnect*"$VPN_SERVER"*) process_ok=1 ;; *) process_ok=0 ;; esac
```

Do not accept `kill -0` alone: PID reuse can turn a stale pidfile into a false
positive. A scoped `pgrep` may be diagnostic fallback, but automatic stop must
still use the helper's exact pidfile validation.

**2. Identify the live tunnel interface**

The current log's `Connected as A.B.C.D` gives the assigned address. Map it to
an interface rather than assuming the highest-numbered `utun` belongs to this
VPN:

```bash
tunnel_if=$(
  /sbin/ifconfig -a | /usr/bin/awk -v ip="$tunnel_ip" '
    /^[[:alnum:]]+:/ { iface=$1; sub(/:$/, "", iface) }
    $1 == "inet" && $2 == ip && iface ~ /^utun[0-9]+$/ { print iface; exit }
  '
)
```

Require a current-attempt log marker plus a live mapped interface. A historical
`Connected as` or `Established DTLS` marker is evidence that startup once
succeeded, not evidence that it is healthy now. DTLS loss alone is not failure
because openconnect can carry traffic over TLS.

If parsing the assigned IP is unavailable, test the configured internal probe
route and take its `utun` interface as the candidate; do not select an arbitrary
`utun`, because macOS and other VPN products create them too.

**3. Validate routes**

```bash
probe_if=$(/sbin/route -n get "$VPN_HEALTH_IP" 2>/dev/null |
  /usr/bin/awk '$1 == "interface:" { print $2; exit }')
case "$probe_if" in utun[0-9]*) route_ok=1 ;; *) route_ok=0 ;; esac
```

Also check the outer gateway route is **not** the VPN tunnel:

```bash
gateway_if=$(/sbin/route -n get "$VPN_GATEWAY_HOST" 2>/dev/null |
  /usr/bin/awk '$1 == "interface:" { print $2; exit }')
case "$gateway_if" in ''|utun[0-9]*) outer_route_ok=0 ;; *) outer_route_ok=1 ;; esac
```

`route -n get` avoids DNS where the argument is an IP. Resolve and cache the
public gateway IP before tunnel startup if `VPN_GATEWAY_HOST` is a name. A route
to the Mac's own assigned tunnel address may report `lo0`, so it is not a useful
route probe.

**4. Discover tunnel DNS servers**

`scutil --dns` is the source of truth for macOS resolver configuration,
including scoped resolvers. Its text format is human-oriented, so parsing must
be conservative. Track resolver blocks whose `if_index` maps to the selected
`utun`, and collect their `nameserver[...]` values. An implementation may map
index to interface with `if_nametoindex` only in native code; in bash, parse the
`interface`/`if_index` text emitted by the current OS and treat inability to map
it as `unknown`, not failure.

A simpler and stronger site-specific option is to configure `VPN_DNS_SERVER`
from the known University VPN configuration and verify its route uses the same
`utun`:

```bash
dns_if=$(/sbin/route -n get "$VPN_DNS_SERVER" 2>/dev/null |
  /usr/bin/awk '$1 == "interface:" { print $2; exit }')
[ "$dns_if" = "$tunnel_if" ]
```

**5. Direct DNS and actual system-resolver probes**

The direct probe establishes that the VPN DNS server is reachable and answers:

```bash
answer=$(/usr/bin/dig +time=2 +tries=1 +short A \
  @"$VPN_DNS_SERVER" "$VPN_HEALTH_HOST" 2>/dev/null) || answer=
```

Validate the answer, not merely `dig`'s exit status. A DNS response such as
NXDOMAIN can still produce a successful command exit. Match a configured
expected IP/prefix using shell `case`, for example `10.*|172.16.*`, but prefer
an exact allow-list when the service is stable.

Then validate the resolver applications actually use:

```bash
system_answer=$(/usr/bin/dscacheutil -q host -a name \
  "$VPN_HEALTH_HOST" 2>/dev/null |
  /usr/bin/awk '$1 == "ip_address:" { print $2 }')
```

The direct check can pass while macOS resolver selection is broken; the system
check catches that half-breakage. Conversely, if the direct query fails but a
cached system answer exists, health is still degraded. DNS checks should use a
low-TTL internal record where available; `dscacheutil` is intentionally testing
the real cached/system path, not forcing a network query.

For the strongest end-to-end probe, open a short TCP connection to a known
internal service after resolving it. Stock `/usr/bin/nc -G 3 -z host port`
works, but only use a service whose owners approve periodic probes. DNS plus
route is the default to avoid generating application traffic.

### Classification

Use observations from the current monitor run, not old log text:

| State | Exact meaning |
|---|---|
| `healthy` | Valid owned PID; current tunnel interface; internal probe and DNS-server routes use that interface; direct DNS answer is expected; system resolver returns an expected answer. |
| `degraded` | PID and tunnel route are present, but direct DNS or system resolver fails/mismatches for 2 consecutive DNS checks. This is the DNS half-up case. |
| `reconnecting` | Valid PID exists, but interface or internal route is absent after a network discontinuity/start; or current log has a reconnect marker. This state has a 90-second grace window. |
| `dead` | No valid owned PID; or PID remains without interface/route beyond 90 seconds; or a definitive current-attempt log line says reconnect timed out/exited. |
| `unknown` | Required health probe configuration is absent, a local check tool errors, or evidence conflicts. Never auto-heal `unknown`. |

One failed packet/DNS query is an observation, not a state transition. Captive
portals and DHCP changes routinely create short convergence windows.

## Auto-heal state machine

Recommended timings:

```text
poll process/interface/route: 20 s
DNS probe:                     60 s
wake/network settle grace:     30 s
reconnecting grace:            90 s
degraded threshold:             2 consecutive DNS failures
healthy reset threshold:        2 consecutive fully healthy checks
```

Transitions:

```text
desired down -> IDLE (never start)
desired up + healthy x2 -> HEALTHY; clear failure counters
HEALTHY + one failed check -> SUSPECT (no action)
SUSPECT + restored -> HEALTHY
SUSPECT + tunnel path present + DNS failure x2 -> DEGRADED
SUSPECT + PID present but path absent -> RECONNECTING for up to 90 s
any state + invalid/missing PID -> DEAD
RECONNECTING beyond 90 s -> DEAD (wedged process)
DEGRADED for 120 s -> HEAL_PENDING
DEAD after 30 s network-settle grace -> HEAL_PENDING
HEAL_PENDING -> one serialized restart -> VERIFYING
VERIFYING + healthy x2 -> HEALTHY
VERIFYING timeout/failure -> BACKOFF
```

Before healing, require basic public network readiness without assuming ICMP:
the public VPN gateway must have a non-`utun` route, and `scutil -r
$VPN_GATEWAY_HOST` must report `Reachable`. Reachability does not prove the
Internet or absence of a captive portal; it only prevents obviously futile
starts. Openconnect startup failure remains authoritative.

Healing uses existing operations only:

1. If the helper-validated VPN PID is alive, run `sudo -n helper stop`.
2. Wait up to 15 seconds for the exact PID to disappear.
3. Run the normal non-interactive start path, which retrieves the user's
   password and pipes it to `sudo -n helper start`.
4. Verify with the strong health checks; helper exit zero is not health.

Never delete a stale root pidfile, kill by pattern, run raw openconnect as root,
or modify routes/DNS directly. If helper stop refuses a stale/reused PID, enter
the circuit breaker and report the actionable error. Widening sudoers to permit
`rm`, `kill`, route manipulation, or arbitrary helper arguments would turn a
bounded VPN lifecycle grant into general root mutation and is not justified.

### Backoff and circuit breaker

Count complete restart attempts, not individual failed probes. Use delays of
`0, 30, 60, 120, 300, 600` seconds, capped at 10 minutes, plus 0-15 seconds of
jitter to avoid synchronized retries after a site outage. Bash 3.2 provides
`$RANDOM`; jitter is not security-sensitive.

Open the circuit after either:

- 5 failed restart attempts within 30 minutes; or
- 3 successful reconnects followed by another failure within 10 minutes each
  (a flap loop).

The open circuit performs no more starts for 60 minutes and sends one
notification. After cooldown, allow one half-open attempt. A strong healthy
state sustained for 10 minutes closes the circuit and clears history. Manual
`auckland-vpn start`/`restart` should clear the circuit because it is an
explicit user decision; ordinary network events should not.

Persist counters and timestamps atomically (`mktemp` in the state directory,
mode 600, then `mv`) so a monitor restart does not forget a flap loop. Validate
all numeric fields when reading; a corrupt state file means conservative reset
to `unknown`, not shell evaluation. Never `source` the state file.

### Notifications and logs

Notify only on meaningful transitions, not every poll:

- recovery succeeded after automatic restart;
- circuit opened after repeated failures;
- action is required (credential, helper, stale pidfile);
- optional: first entry into degraded state if it lasts 2 minutes.

From a LaunchAgent user session:

```bash
/usr/bin/osascript -e 'display notification "VPN recovery paused after repeated failures" with title "Auckland VPN"'
```

Do not interpolate raw log/error text into AppleScript source. Pass only fixed
messages or safely escape values. Notifications are best effort and must never
change monitor state. Append timestamped transitions and command exit classes
to `monitor.log`, rotate it at a small bound (for example 256 KiB), mode 600,
and never log passwords, TOTP material, or command lines containing them.

## Security boundary

Everything observed by the monitor is unprivileged. The only root actions are
the existing fixed helper commands. This is a good boundary because:

- the generated, root-owned helper fixes server, username, binaries, script,
  secret path, log path, pidfile, and openconnect arguments;
- `stop` validates that the exact pidfile PID is this VPN before signaling it;
- sudoers does not expose arbitrary arguments, shell, `kill`, file deletion,
  route changes, or raw openconnect;
- the user's password is sent on stdin, as it already is for manual start.

No sudoers change is recommended. The feature should refuse unattended healing
unless both `sudo -n helper start` (with an intentionally empty password input,
expecting the helper's `no VPN password` error rather than a sudo policy error)
and `sudo -n helper stop` policy can be established safely. Because `stop`
changes state, policy validation should preferably use `sudo -l` exact-command
inspection during setup rather than invoke it against a live tunnel.

The residual trust in user/admin-writable Homebrew binaries already exists in
the generated helper and is not widened by monitoring.

## Rollout sequence

1. Add a `health` command that prints one machine-readable state and a concise
   reason, with optional `--json` only if it can be emitted without a new JSON
   dependency. Keep `status` human-oriented.
2. Add configured internal host/IP/DNS probes and test each classifier with
   command-output fixtures. DNS health must not ship as “healthy” without a
   known expected answer.
3. Add `monitor` foreground mode with `--once`, `--dry-run`, state persistence,
   intent, lock, hysteresis, and circuit breaker. Test state transitions with a
   fake clock and fake health/executor functions.
4. Integrate start/stop intent semantics. Distinguish user stop from the
   monitor's internal restart stop.
5. Add LaunchAgent install/uninstall commands using `~/Library/LaunchAgents` and
   modern `launchctl bootstrap gui/$(id -u)` / `bootout`, with absolute paths.
6. Run failure drills without changing privileges: kill the owned process,
   disable Wi-Fi briefly, wake after more than five minutes, and temporarily use
   a deliberately failing health hostname. Confirm thresholds, logs, desired
   state, and circuit behavior before enabling automatic action by default.

## Rejected shortcuts

- Raising `--reconnect-timeout` to hours helps sleep but does not repair a
  wedged process, broken system DNS, changed interfaces, or captive portals. It
  may be a useful complementary tuning change, not the watchdog.
- `KeepAlive.NetworkState` is too coarse: “some network is up” does not mean the
  gateway is usable, and captive portals appear up.
- Parsing old connected log markers as current health produces false green
  status after route/DNS loss.
- Automatically restarting whenever no PID exists overrides intentional stop.
- Root `LaunchDaemon`, root network hooks, and broader sudoers grants add secret
  and privilege complexity without improving the health decision.
