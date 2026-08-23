# Auckland University VPN — reliable setup

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
- **Certificate handling.** We trust the system's Certificate Authorities (the
  gateway cert is from DigiCert). We deliberately don't pin a specific cert,
  because the university's gateway cert rotates — pinning would just break later.

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

## One-time setup

1. **Install the script** (no sudo needed — `/opt/homebrew/bin` is on your PATH):

   ```bash
   cp auckland-vpn /opt/homebrew/bin/auckland-vpn
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
   password. Without it, everything still works — `start` just asks for your
   Mac password once per connection instead.

## Daily use

```bash
auckland-vpn start      # connect (auto 2FA + auto-reconnect); verifies the
                        # tunnel really came up before saying so
auckland-vpn status     # Connected as you (pid, tunnel IP) / Connecting... /
                        # Not connected.
auckland-vpn log        # last 50 log lines ('auckland-vpn log -f' follows)
auckland-vpn stop       # disconnect
auckland-vpn restart    # stop, confirm the old process is gone, start again
auckland-vpn doctor     # check every prerequisite; OK/FIX + exact fix each
```

Running bare `auckland-vpn` (or an unknown command) shows help and exits 2 —
it never touches the network implicitly.

## Certificates

We rely on your Mac's built-in trusted Certificate Authorities (the gateway cert
is from DigiCert), so certificate rotation is handled automatically — nothing to
update. The `auckland-vpn pin` command still prints the current cert fingerprint
if you ever want to inspect it, but pinning is not used.

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
  use `auckland-vpn restart`, which confirms the old process is gone first.
- **After upgrading this tool, or after `brew upgrade openconnect`, re-run
  `auckland-vpn setup-sudo`.** The privileged helper embeds the log path and
  other settings at install time, and it uses its own root-owned **copy** of
  the vpnc-script (`/private/etc/auckland-vpn/vpnc-script`) that setup-sudo
  stages from Homebrew — so an old helper keeps writing to old locations and
  running an old vpnc-script until regenerated.
- **Sudo behaviour of `start`:** passwordless once `setup-sudo` is done;
  otherwise it asks for your Mac password once (in non-interactive shells it
  explains how to install the helper instead of hanging).
- **Sleep/wake:** openconnect tries to reconnect for up to 5 minutes
  (`--reconnect-timeout=300`). If your Mac slept longer than that, the tunnel
  is dead — run `auckland-vpn restart` (or check `auckland-vpn status`, which
  tells you connected vs connecting vs not connected).

## Uninstall

```bash
auckland-vpn stop                                            # disconnect
sudo rm /etc/sudoers.d/auckland-vpn                          # remove sudo rule
sudo rm -rf /private/etc/auckland-vpn                        # remove helper + pidfile + staged vpnc-script
sudo rm -rf /private/var/log/auckland-vpn                    # remove the log directory
security delete-generic-password -s auckland-vpn             # remove stored password
rm -rf ~/.config/auckland-vpn ~/.local/state/auckland-vpn    # remove config + state
rm /opt/homebrew/bin/auckland-vpn                            # remove the script itself
```
