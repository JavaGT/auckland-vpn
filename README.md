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

   It also prints an *optional* one-liner that lets `auckland-vpn start` run
   without asking for your Mac password. Recommended for true one-command use.

## Daily use

```bash
auckland-vpn start      # connect (auto 2FA + auto-reconnect)
auckland-vpn status     # is it up?
auckland-vpn log        # watch the connection log
auckland-vpn stop       # disconnect
```

## Certificates

We rely on your Mac's built-in trusted Certificate Authorities (the gateway cert
is from DigiCert), so certificate rotation is handled automatically — nothing to
update. The `auckland-vpn pin` command still prints the current cert fingerprint
if you ever want to inspect it, but pinning is not used.

## Notes

- The TOTP secret lives at `~/.config/auckland-vpn/totp-secret` (mode 600).
- The VPN password lives in your macOS Keychain (service name `auckland-vpn`),
  or, if Keychain couldn't be used, in `~/.config/auckland-vpn/vpn-password`
  (mode 600).
- To change either later: `auckland-vpn setup` (it re-runs the wizard).
