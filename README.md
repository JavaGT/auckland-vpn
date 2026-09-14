# Auckland University VPN — reliable setup

[![tests](https://github.com/JavaGT/auckland-vpn/actions/workflows/tests.yml/badge.svg)](https://github.com/JavaGT/auckland-vpn/actions/workflows/tests.yml)

This replaces your flakey manual command:

```
sudo openconnect --protocol=fortinet --user=YOUR_USERNAME "connectvpn.auckland.ac.nz/client"
```

with a single, dependable command: `auckland-vpn start`.

## Why the old way was flakey

- **You had to type a 2FA code by hand.** If it took too long, the code
  expired and the login failed. We fix this by letting openconnect *generate*
  the code itself from a secret (it acts as your authenticator app).
- **No auto-reconnect.** If the tunnel dropped, you had to notice and reconnect
  manually. We add `--reconnect-timeout` so it recovers on its own.
- **DNS was set up inconsistently** (the usual "connected but sites won't load"
  symptom). The Homebrew `vpnc-script` already on your Mac fixes DNS properly;
  this script makes sure it's used.
- **Certificate handling.** We rely on OpenConnect's default CA verification —
  for this Homebrew build that is GnuTLS with the Mozilla root store (Homebrew
  `ca-certificates`), not the macOS Keychain (the gateway cert is from
  DigiCert). We deliberately don't pin a specific cert, because the
  university's gateway cert rotates — pinning would just break later.

## Configuration (your username)

The script does **not** contain your VPN username — set it one of two ways
before running `auckland-vpn setup` / `start`:

- **environment variable:** `export VPN_USER=yourusername` (e.g. in your shell
  profile), or
- **a private file** `~/.config/auckland-vpn/config` containing a line
  `VPN_USER=yourusername` (that file is yours and is not part of this repo).

The config file is **parsed, not executed**: only blank lines, `#comments`,
and `VPN_USER=<username>` lines are accepted — anything else is rejected with
an error naming the file and line. (`setup` will offer to write the username
there for you if it isn't set yet.)

The username value itself is limited to letters, digits, and `@ . _ -` — no
spaces. Surrounding whitespace is trimmed, and one pair of matching quotes
(`"..."` or `'...'`) is stripped. The same rule applies wherever the username
comes from: the config file, the `VPN_USER` environment variable, and the
`setup` prompt.

## One-time setup

1. **Install the script** (no sudo needed — use your Homebrew prefix:
   `/opt/homebrew` on Apple Silicon, `/usr/local` on Intel):

   ```bash
   cp auckland-vpn /opt/homebrew/bin/auckland-vpn   # /usr/local/bin/... on Intel
   chmod +x /opt/homebrew/bin/auckland-vpn
   ```

2. **Get your TOTP secret from the university.** You chose to re-enrol a token.
   Log in to the University of Auckland MFA / identity portal, add (or reset) a
   TOTP token, and the enrolment page will show a **secret key** — a string like
   `JBSWY3DPEHPK3PXP` (sometimes shown next to the QR code). Copy that string.
   (If you'd rather keep your phone working too, export the secret from your
   current authenticator app instead — same string, both can use it.)

3. **Run the setup wizard:**

   ```bash
   auckland-vpn setup
   ```

   It will ask for:
   - the **TOTP secret** you copied in step 2 (saved to a private file),
   - your **University password** (saved to your macOS Keychain — you'll get a
     system prompt to allow it; if Keychain can't prompt in your shell it falls
     back to a protected file).

   It also offers an *optional* one-liner that installs a restricted,
   root-owned helper so `auckland-vpn start` runs without typing your Mac
   password. That helper is what launches the tunnel, so `start` needs it:
   if you skip this step now, `start` will tell you to run `setup-sudo`
   before it can connect.

## Daily use

```bash
auckland-vpn start      # connect (auto 2FA + auto-reconnect); verifies the
                        # tunnel really came up before saying so
auckland-vpn status     # Connected as you (pid, tunnel IP) / Connecting... /
                        # Not connected.
auckland-vpn log        # last 50 log lines ('auckland-vpn log -f' follows)
auckland-vpn stop       # disconnect
auckland-vpn restart    # stop, wait out the old process, start again (a
                        # survivor makes the start refuse rather than race)
auckland-vpn doctor     # check every prerequisite; OK/FIX + exact fix each
auckland-vpn monitor    # optional watchdog that auto-heals a dead tunnel
                        # (foreground; see "Auto-heal monitor" below)
auckland-vpn diagnose   # doctor checks + failure analysis of the last attempt
```

Running bare `auckland-vpn` (or an unknown command) shows help and exits 2 —
it never touches the network implicitly.

## Certificates

We rely on OpenConnect's default CA verification — this Homebrew build uses
GnuTLS with the Mozilla root store (Homebrew `ca-certificates`), not the macOS
Keychain — and the gateway cert is from DigiCert, so certificate rotation is
handled automatically; nothing to update. Troubleshooting note: a root CA you
add to your Keychain is *not* automatically trusted here. The `auckland-vpn
pin` command still prints the current cert fingerprint if you ever want to
inspect it, but pinning is not used.

## Notes

- Works with any Homebrew layout — Apple Silicon (`/opt/homebrew`), Intel
  (`/usr/local`), or a custom prefix; the script resolves the right paths at
  startup.
- The TOTP secret lives at `~/.config/auckland-vpn/totp-secret` (mode 600).
- The VPN password lives in your macOS Keychain (service name `auckland-vpn`),
  or, if Keychain couldn't be used, in `~/.config/auckland-vpn/vpn-password`
  (mode 600).
- To change either later: `auckland-vpn setup` (it re-runs the wizard).
- **Logs** live in `/private/var/log/auckland-vpn/auckland-vpn.log` — a
  file owned by *you* (mode 600) inside a **root-owned directory** created
  by `setup-sudo`. The privileged helper only ever *appends* to it; it
  never recreates or re-owns the file at runtime. Each attempt stamps a
  `==== auckland-vpn start <date> ====`
  banner and `status`/`log` read only the latest attempt, so history is
  easy to compare even though the file keeps growing.
- **The helper reads nothing from your home directory.** At start, this
  script looks up your password in the Keychain, reads the TOTP secret
  from `~/.config/auckland-vpn/totp-secret` itself, and hands both to the
  privileged helper over its standard input — root-side code never opens
  a user-owned path. The pidfile stays at
  `/private/etc/auckland-vpn/vpn.pid`, owned by root, mode 644. It is
  pre-created by `setup-sudo` and kept across stops: between runs it may
  be empty or hold a stopped attempt's PID — readers treat both as
  "nothing running", and each start truncates it before launching.
- **Password limitation:** a stored password must not contain a raw
  newline character. `start` hands the password and the TOTP secret to
  the privileged helper as two newline-framed records, so a newline
  inside a password would corrupt the framing — it is rejected up front.
  Spaces, `\r`, and every other character pass through unchanged. Re-run
  `auckland-vpn setup` if you ever hit this message.
- **`start` verifies the tunnel**: it polls for connected evidence for up to
  ~15 s ("verifying . . ."), prints `Connected as <user>. Tunnel IP: ...` on
  success, and on failure dumps the last 15 log lines inline before pointing
  at `auckland-vpn log`.
- **One tunnel at a time**: starting while already connected is refused —
  use `auckland-vpn restart`, which waits out the old process first; if it
  somehow survived, the start half refuses rather than racing it.
- **After upgrading this tool, or after `brew upgrade openconnect`, re-run
  `auckland-vpn setup-sudo`.** The privileged helper embeds the log path and
  other settings at install time, and it uses its own root-owned **copy** of
  the vpnc-script (`/private/etc/auckland-vpn/vpnc-script`) that setup-sudo
  stages from Homebrew — so an old helper keeps writing to old locations and
  running an old vpnc-script until regenerated.
- **Sudo behaviour of `start`:** `start` needs the privileged helper that
  `setup-sudo` installs — without it, it exits with that exact instruction.
  Once installed, connecting is passwordless; if the helper exists but its
  passwordless rule is not active (e.g. the sudoers fragment was removed),
  `start` asks for your Mac password once (in non-interactive shells it
  explains how instead of hanging).
- **Sleep/wake:** OpenConnect retries a dropped tunnel for up to 5 minutes
  (`--reconnect-timeout=300`) — but ONLY if the FortiGate allows the old
  session cookie to be reused, which is server-dependent and often NOT the
  case. After sleep/wake (or any long network change) you may therefore need
  a **fresh authentication**: run `auckland-vpn restart`, which re-authenticates
  with your stored credentials and a brand-new TOTP code. The optional
  `monitor` command below automates exactly that.
- **Realm evidence:** on a successful login openconnect logs
  `Got login realm 'client'`. If that line is missing from an attempt,
  `auckland-vpn diagnose` flags it — that points at a realm/URL-path issue,
  not necessarily bad credentials.

## Auto-heal monitor (optional)

`auckland-vpn monitor` is a foreground watchdog for when you want the tunnel
kept up without babysitting it.

**What it does** (design: `docs/consults/reliability.md`):

- polls every 20 s using unprivileged checks only. Out of the box it checks
  the one signal it can always trust: is the pidfile PID alive and still our
  openconnect. Three finer probes — a `utun` interface carrying the tunnel
  IP, the route to a university-internal IP, and end-to-end DNS through the
  VPN resolver (vs. the system resolver) — switch on only when you configure
  `VPN_HEALTH_HOST`, `VPN_HEALTH_IP` and `VPN_DNS_SERVER` (see knobs below);
  until then those observations report `unknown` and only a dead tunnel is
  acted on;
- classifies `healthy / reconnecting / degraded / dead` with hysteresis so
  one blip never triggers action: ~90 s reconnect grace, 2 consecutive DNS
  failures before "degraded" (configured probes only), ~30 s network-settle
  grace after death/wake;
- heals a broken tunnel **only if you asked for one** — `start`/`restart`
  mark the VPN wanted-up and `stop` un-marks it, so it never resurrects a
  tunnel you intentionally stopped;
- healing reuses the existing passwordless helper grant (`helper stop`, then
  the same credential plumbing `start` uses) — **no new sudo rights**;
- backs off exponentially between restarts (30 s → … → 15 min cap); after 5
  failed attempts it opens a circuit breaker: no more starts for an hour,
  plus a macOS notification. A manual `auckland-vpn start` clears it.

**What it does NOT do:** no launchd/LaunchAgent installation, no root daemon,
no auto-start at boot. Why (per the consult): plain polling survives sleep
and network changes without private macOS event APIs, and a per-user
foreground process keeps credential access and notifications inside YOUR
login session — a root daemon would add privilege and secret-handling risk
without improving the health decision. Supervise it yourself:

```bash
nohup auckland-vpn monitor >/dev/null 2>&1 &   # start watching
pkill -f "auckland-vpn monitor"                # stop watching
auckland-vpn monitor --once                    # single check, then exit
```

Handy knobs (environment variables): `INTERVAL`, `RECONNECT_GRACE`,
`DEGRADED_THRESHOLD`, `DEGRADED_GRACE`, `NETWORK_SETTLE_GRACE`,
`MAX_RESTART_ATTEMPTS`, `CIRCUIT_COOLDOWN`, `BACKOFF_CAP`. Deep probes also
need site values: `VPN_HEALTH_HOST` (a hostname the VPN's DNS should
resolve, e.g. an internal health record), `VPN_HEALTH_IP` (a stable
university-internal IP whose route must use the tunnel), and
`VPN_DNS_SERVER` (the VPN resolver IP pushed to the tunnel). Set
`AUCKLAND_VPN_DRY_RUN=1` to log what it *would* do without ever invoking
sudo. State/counters live in `~/.local/state/auckland-vpn/`
(`monitor-state`, `monitor.log`, `monitor.lock`); `doctor` reports whether
the monitor is running and its last recorded state.

## Known limitations

- **Split DNS (upstream):** OpenConnect 9.x does not implement FortiNet's
  dedicated `<split-dns>` configuration — it logs
  `WARNING: Got split-DNS ... (not yet implemented)` and ignores it — so
  university-internal names that depend on split-DNS may not resolve even
  though the tunnel is up. No wrapper-side setting can fix this; it needs an
  upstream OpenConnect change (`docs/consults/openconnect-audit.md` §5).
- **Reconnect ≠ reauthentication:** Fortinet cookie reuse across drops is
  server-dependent — see the sleep/wake note above; plan on
  `auckland-vpn restart` doing a fresh login rather than resuming.

## Testing

The suite is plain Bash, no framework: `tests/run-tests.sh`. It covers static
checks (`bash -n`, ShellCheck on the wrapper AND the generated privileged
helper, plus security greps), unit tests of sourced functions, contract tests
of the sudo/helper boundary with a fake `sudo`, and integration tests against
a stubbed `openconnect` — all in private sandboxes.

Run it locally (no sudo needed):

```bash
tests/run-tests.sh          # requires bash + shellcheck (brew install shellcheck)
```

Focused iteration: `tests/run-tests.sh <substring>...` runs only the tests
whose names match (e.g. `tests/run-tests.sh monitor`).

CI runs exactly that script on a GitHub Actions macOS runner (see
`.github/workflows/tests.yml`) — no root, no network access. What is **not**
automated and stays manual-only:

- the real privileged install (`auckland-vpn setup-sudo`: root ownership,
  `/etc/sudoers.d` fragment, real `visudo`),
- macOS Keychain authorization prompts,
- connecting to the live University VPN (credentials, DNS/routes).

**Contributing:** keep changes green — run `tests/run-tests.sh` before sending
a PR; it must pass on stock macOS with only Homebrew ShellCheck installed.

## Uninstall

```bash
pkill -f "auckland-vpn monitor"                               # stop monitor
auckland-vpn stop                                            # disconnect
sudo rm /etc/sudoers.d/auckland-vpn                          # remove sudo rule
sudo rm -rf /private/etc/auckland-vpn                        # remove helper + pidfile + staged vpnc-script
sudo rm -rf /private/var/log/auckland-vpn                    # remove the log directory
security delete-generic-password -s auckland-vpn             # remove stored password
rm -rf ~/.config/auckland-vpn ~/.local/state/auckland-vpn    # remove config + state
rm /opt/homebrew/bin/auckland-vpn                            # remove the script itself
```
