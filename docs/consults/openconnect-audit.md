# OpenConnect / Fortinet / macOS technology audit

Date: 2026-08-23

Scope: OpenConnect 9.21 from Homebrew on macOS, using `--protocol=fortinet`, the Homebrew `vpnc-script`, password authentication, and software TOTP. No VPN connection was attempted.

## Confidence legend

- **CONFIRMED**: supported directly by OpenConnect 9.21 help/man page, the 9.21 Fortinet implementation, the installed Homebrew package, or the installed `vpnc-script`.
- **PLAUSIBLE**: operational inference or behavior dependent on the University FortiGate/macOS version; verify with a real, redacted diagnostic before implementing.

## Prioritized findings

| Priority | Finding | Evidence | Confidence |
|---|---|---|---|
| P1 | Add `--non-inter`. The helper supplies one password on stdin, but OpenConnect can fall back to manual token entry if the server rejects the software token or presents an unsupported form. A background/root helper must fail rather than wait for input it cannot receive. | OpenConnect help defines `--non-inter` as exiting if input is required; token code contains the message `Server is rejecting the soft token; switching to manual entry`. | **CONFIRMED** |
| P1 | `/client` is an initial URL path, not unconditionally the selected Fortinet realm. For Fortinet it becomes a realm only if the gateway redirects it to a URL containing `realm=client`; `--authgroup=client` is the direct form-selection mechanism if needed. | `--usergroup` and URL path are equivalent; Fortinet source extracts `realm=` from the redirect and logs `Got login realm '...'`. | **CONFIRMED** |
| P1 | Fortinet-specific split-DNS is not implemented in OpenConnect 9.21. `vpnc-script` can consume `CISCO_SPLIT_DNS`, but Fortinet parsing only warns about `<split-dns>` and does not export it. | OpenConnect 9.21 `fortinet.c`: `WARNING: Got split-DNS domains ... (not yet implemented)`. | **CONFIRMED** |
| P1 | The README overstates Fortinet reconnect reliability. Five minutes is the OpenConnect default, but many FortiGates cannot reuse the authenticated cookie after a drop; sleep/wake or adapter roaming may therefore require a fresh full login, not merely a retry. | OpenConnect Fortinet documentation and source describe reconnect as server/version/config dependent and problematic. | **CONFIRMED** |
| P2 | DTLS should remain enabled. Fortinet mode prefers PPP over DTLS and falls back to PPP over TLS automatically; forcing TLS normally worsens TCP traffic because it creates TCP-over-TCP behavior. | Official Fortinet protocol documentation. | **CONFIRMED** |
| P2 | Homebrew OpenConnect does validate the CA chain and hostname by default, but “macOS built-in CAs” is inaccurate for this installation. Homebrew GnuTLS depends on Homebrew `ca-certificates`, documented as Mozilla's CA store. | Installed OpenConnect uses GnuTLS 3.8.13; Homebrew dependency metadata identifies `ca-certificates` as the Mozilla CA store. | **CONFIRMED** |
| P2 | The shipped `vpnc-script` mutates both dynamic-store DNS and the active physical network service's DNS. Its errors are redirected away, active-service discovery is text parsing, and disconnect sets that service to `Empty`; these are meaningful modern-macOS failure risks. | Installed `/opt/homebrew/etc/vpnc/vpnc-script`, lines 642-758. | **CONFIRMED** |
| P2 | Do not tune `--dtls-ciphers`, compression, DPD, or MTU globally without evidence. Defaults are appropriate; these flags are diagnostic levers for specific symptoms. | OpenConnect defaults and Fortinet server configuration supply DTLS/DPD details; `vpnc-script` already falls back to MTU 1412. | **CONFIRMED** |
| P2 | Add a verbose, redacted diagnostic mode, but never use `--dump-http-traffic` in a shareable report. HTTP dumps can include authentication forms, cookies, and server configuration. | OpenConnect help says HTTP traffic dump includes request/response bodies. | **CONFIRMED** |
| P3 | 9.21 is materially better for this wrapper: it accepts unpadded base32 token secrets; 9.20 added `otpauth://` HOTP/TOTP URI support and preserved full URL paths through authentication. | OpenConnect 9.20/9.21 changelog. | **CONFIRMED** |
| P3 | Optional pinning is possible, but a one-fingerprint TOFU mode conflicts with deliberate certificate rotation and TOFU does not protect the first retrieval. Keep CA validation as the default. | `--servercert` disables system trust and accepts one or more SHA-1/SHA-256/SPKI pins. | **CONFIRMED** |

## 1. Authentication robustness

### Current state

The invocation uses:

```text
--user="$VPN_USER" --passwd-on-stdin --token-mode=totp --token-secret="@$TOKEN_SECRET"
```

The setup normalizes a raw secret to `base32:...` and also accepts an `otpauth://` URI. OpenConnect 9.21 supports both formats. **CONFIRMED**

For a FortiGate which first requests username/password and then presents one of OpenConnect's supported token challenge forms, this is the correct automated combination: the stdin value fills the password field and OpenConnect generates a fresh RFC 6238 code when it recognizes the token field. **CONFIRMED**

The literal server URL `connectvpn.auckland.ac.nz/client` sets the initial URL path. This is equivalent to `--usergroup=client`. In the Fortinet implementation, that path is treated as a realm only when FortiGate redirects to (for example) `/remote/login?realm=client`; OpenConnect then logs `Got login realm 'client'` and includes it in login submissions. It is therefore too strong to comment that the URL “includes the client realm” without observing that log. **CONFIRMED**

`--authgroup=client` is different: it attempts to select a realm/authgroup field presented in an authentication form. Do not add it unless a diagnostic shows a selectable realm or the `/client` redirect does not produce `Got login realm 'client'`. **CONFIRMED**

### Risk / opportunity

OpenConnect Fortinet supports two known challenge styles, `tokeninfo` and HTML forms. A deployment using SAML/external-browser auth, a novel FortiOS form, or another challenge layout can still fail. **CONFIRMED**

If automatic TOTP is rejected, generic token handling may switch to manual entry. The generated helper has no usable interactive input after its single piped password, and it is background-oriented. This should fail immediately rather than potentially issue a prompt or consume EOF ambiguously. **CONFIRMED**

If the University password changes while the stored Keychain password remains old, the next new authentication sends the old password. TOTP validity does not help: the initial credential step fails before, or together with, the token challenge. An already authenticated tunnel/cookie is separate and may continue until the server expires it or a reconnect requires authentication. The exact FortiGate policy is deployment-dependent. **PLAUSIBLE**

FortiGate's protocol is often unable to identify “wrong password” versus “wrong token” with certainty. In OpenConnect's implementation, HTTP 405 is mapped to the combined message `Invalid credentials; try again.` A token-specific message such as `Server is rejecting the soft token` is stronger evidence, but absence of it is not proof that the password was wrong. **CONFIRMED**

### Recommendation

Add one production flag:

```diff
       --passwd-on-stdin \
+      --non-inter \
       --token-mode=totp \
```

Keep `/client` initially. During a diagnostic, require evidence of:

```text
Got login realm 'client'
```

If the gateway instead exposes a realm selector and requires `client`, test this exact change:

```diff
+      --authgroup=client \
```

Do not blindly combine realm mechanisms as a permanent compatibility shim. **CONFIRMED**

Classify authentication logs conservatively:

- `Server is rejecting the soft token` or `Failed to generate OTP tokencode`: token-specific.
- `Invalid credentials; try again.`: password-or-token, not password-specific.
- Missing `Got login realm 'client'`: realm/path investigation needed, not authentication proof.

On combined invalid credentials, recommend `auckland-vpn setup` to refresh the password and TOTP together rather than asserting which one failed. **CONFIRMED**

## 2. Transport quality

### Current state

DTLS is enabled unless `--no-dtls` is supplied and the installed build reports the DTLS feature. For Fortinet, OpenConnect attempts PPP-over-DTLS and falls back to PPP-over-TLS if DTLS fails. **CONFIRMED**

Expected useful log markers include `DTLS is enabled on port ...`, `Established DTLS connection ...`, `PPP over TLS`, DTLS handshake failures, and PPP reconnect failures. Exact visibility depends on log level. **CONFIRMED**

### Risk / opportunity

UDP/DTLS may be blocked or degraded by a captive portal, firewall, NAT, or path-MTU black hole. TLS fallback is more likely to traverse restrictive networks but can perform poorly for TCP applications because packet loss affects both nested TCP layers. **CONFIRMED** for the fallback/performance mechanism; campus incidence is **PLAUSIBLE**.

The installed `vpnc-script` uses a server-provided tunnel MTU when available and otherwise defaults to 1412 on macOS. `--base-mtu` tells OpenConnect the unencrypted path MTU so it can derive tunnel MTU; `--mtu` directly requests tunnel MTU and is documented primarily for legacy servers. **CONFIRMED**

`--dtls-ciphers` restricts negotiation. There is no observed cipher failure here, so restricting it creates compatibility risk without solving ordinary UDP or MTU problems. **CONFIRMED**

OpenConnect defaults to stateless compression only where supported. `--deflate` enables stateful compression; stateful compression is inappropriate as a reliability tweak and increases state/recovery complexity. Whether this Fortinet deployment negotiates any applicable compression is unverified. **CONFIRMED** for flag semantics; Fortinet negotiation is **PLAUSIBLE**.

### Recommendation

Keep DTLS and cipher/compression defaults: no production flag change. Do not add `--no-dtls`, `--dtls-ciphers`, `--deflate`, or `--no-deflate`. **CONFIRMED**

For diagnosis only, compare one normal attempt against:

```text
--no-dtls
```

If only large transfers stall while pings/small requests work, test a reduced outer-path estimate:

```text
--base-mtu=1400
```

Treat 1400 as an A/B diagnostic, not a justified permanent value. Capture the successful DTLS/TLS mode and negotiated/applied MTU before changing defaults. **PLAUSIBLE**

## 3. Resilience flags

### Current state

`--reconnect-timeout=300` is sensible but redundant: 300 seconds is OpenConnect's default. It means “keep retrying for up to 300 seconds after disconnection/DPD,” not “guarantee a valid Fortinet session for five minutes.” **CONFIRMED**

Fortinet reconnect is unusually fragile. Older FortiGate versions cannot reuse the cookie after a drop. Newer servers have `tun-connect-without-reauth`, but reconnect can still be restricted to the same source IP and a short server-side window. OpenConnect logs whether the server says reconnect-after-drop is allowed and under what conditions. **CONFIRMED**

Sleep/wake commonly changes timing, local interface, and sometimes public source IP. OpenConnect can attempt recovery, but there is no client flag that repairs a FortiGate policy requiring reauthentication; noninteractive automatic reauthentication would also require a fresh TOTP challenge. **CONFIRMED** for protocol limitations; exact University behavior is **PLAUSIBLE**.

### Risk / opportunity

The README currently promises more than the flag provides and says a sleep longer than five minutes necessarily kills the tunnel. The timer applies after OpenConnect detects disconnection, so wall-clock sleep duration is not necessarily identical to retry duration. **CONFIRMED**

`--force-dpd=INTERVAL` overrides server DPD timing. Fortinet configuration normally supplies a heartbeat interval, and forcing a more aggressive interval can cause needless reconnects on a briefly paused/sleeping Mac. **CONFIRMED**

`--base-mtu` addresses path MTU, not general resilience. `--non-inter` improves deterministic failure behavior, not reconnect success. OpenConnect HEAD has a future `--tcp-keepalive` option, but 9.21 does not expose it and it should not be designed into this wrapper yet. **CONFIRMED**

### Recommendation

Keep the explicit timeout for readability, or remove it with no behavior change:

```diff
-      --reconnect-timeout=300 \
```

No `--force-dpd` should be added. Add `--non-inter` as described above. Change product wording to “OpenConnect retries temporary drops for up to five minutes when the FortiGate permits cookie reuse; sleep/wake may still require `restart`.” **CONFIRMED**

A future wake agent could detect a dead process and invoke a fresh `start`, but it would be new macOS lifecycle machinery rather than an OpenConnect flag and should be designed explicitly. **PLAUSIBLE**

## 4. Security posture and trust store

### Current state

Without `--servercert`, `--no-system-trust`, or a custom `--cafile`, OpenConnect performs normal certificate-chain and hostname/SNI verification. This behavior is protocol-independent and applies to Fortinet. Failure strings distinguish untrusted/invalid certificates and hostname mismatch. **CONFIRMED**

For this Homebrew build, “system trust” means the default trust available to GnuTLS, not necessarily the macOS Keychain trust settings. The installed dependency chain is OpenConnect -> GnuTLS -> Homebrew `ca-certificates`, whose formula describes a Mozilla CA certificate store. Thus public DigiCert validation should work, but a locally installed university/private root in Keychain may not automatically be trusted. **CONFIRMED** for this installation.

The current `pin` command calculates a SHA-256 fingerprint of the leaf certificate and formats it as `sha256:...`, suitable as the certificate-style `--servercert` value. `--servercert` implies `--no-system-trust`; it replaces CA/hostname trust rather than adding a second check. Multiple pins can be supplied for planned rotation. `pin-sha256:` is the RFC 7469/SPKI public-key form. **CONFIRMED**

### Risk / opportunity

Deliberate CA-based trust is a sound default for a publicly certified, rotating institutional gateway. A TOFU fetch can be intercepted on first use, and a leaf-certificate pin will break on routine renewal. SPKI pinning may survive renewal only if the same key is reused, which must not be assumed. **CONFIRMED** for security properties; University key reuse is **PLAUSIBLE**.

The README's “Mac built-in trusted CAs” claim can mislead troubleshooting, especially for user-added Keychain roots. **CONFIRMED**

### Recommendation

Keep the connection invocation unpinned. Change documentation to “Homebrew OpenConnect's default GnuTLS CA store (Mozilla roots), with hostname verification.” **CONFIRMED**

Do not turn the current `pin` display into one-click TOFU by default. If optional strict pinning is implemented, require an explicit configured pin and allow overlap during rotation:

```text
--servercert=sha256:OLD_CERT_HASH --servercert=sha256:NEW_CERT_HASH
```

Label this “manual strict pinning,” not stronger automatic trust. A `pin-sha256:` SPKI mode can also be offered, but only after an administrator publishes/stably confirms the gateway key. **CONFIRMED**

## 5. DNS and split tunnel on modern macOS

### Current state

OpenConnect 9.21 parses Fortinet IPv4/IPv6 addresses, ordinary DNS servers, DNS search domains attached to `<dns>`, and split include/exclude routes. It explicitly does not implement Fortinet's dedicated `<split-dns domains=... dnsserver...>` configuration. **CONFIRMED**

The generic `vpnc-script` can handle ordinary `INTERNAL_IP4_DNS`, `CISCO_DEF_DOMAIN`, routes, and (on some platforms) `CISCO_SPLIT_DNS`. But because OpenConnect does not export Fortinet split-DNS, no script can reconstruct it from its environment. A custom script alone cannot fix that upstream information loss. **CONFIRMED**

On Darwin, the installed script:

- writes dynamic-store entries under `State:/Network/Service/$TUNDEV/{DNS,IPv4}`;
- generally sets `OverridePrimary`, so VPN DNS becomes primary rather than true per-domain split DNS;
- also finds the current physical service through `route` plus parsed `networksetup` output and runs `networksetup -setdnsservers ...`;
- suppresses `scutil` errors;
- resets the active physical service's DNS to `Empty` on disconnect instead of explicitly restoring a captured prior static list.

These are direct properties of the installed script. **CONFIRMED**

### Risk / opportunity

Common “connected but cannot resolve” classes are:

- FortiGate supplied dedicated split-DNS: log contains `WARNING: Got split-DNS ... (not yet implemented)`. **CONFIRMED**
- No usable DNS was pushed: no `Got IPv4 DNS server ...` lines. **CONFIRMED**
- DNS server was pushed but has no route/reachability through the tunnel: `Got IPv4 DNS server ...` exists, but direct DNS queries time out. **PLAUSIBLE**
- `vpnc-script` failed or selected the wrong active network service: tunnel establishes, but `scutil --dns` does not show VPN resolvers. Error details may be absent because the script redirects them. **CONFIRMED**
- Stale dynamic-store or physical-service DNS survives an unclean crash/kill: subsequent `scutil --dns` output is inconsistent until cleanup/network reconfiguration. **PLAUSIBLE**
- Search-domain-only failure: fully qualified internal names work, short names do not; inspect `Got search domain ...` and `SearchDomains`. **PLAUSIBLE**

### Recommendation

Do not immediately vendor a custom `vpnc-script`. First diagnose and, if needed, advance/fix OpenConnect's Fortinet split-DNS parser; that is the root cause and benefits every downstream script. **CONFIRMED**

Add post-connect diagnostic capture (read-only commands):

```text
scutil --dns
route -n get <internal-dns-ip>
ifconfig <utun-interface>
netstat -rn -f inet
```

The exact internal DNS address should come from `Got IPv4 DNS server ...`; do not hardcode one. Avoid `dig @server name` in a default diagnostic unless an internal test hostname is known, because it performs network traffic and may expose a private query. **CONFIRMED**

A staged custom macOS script becomes preferable only if diagnostics prove the Homebrew script's physical-service mutation is causing harm. Such a script should use only `scutil` dynamic-store entries, preserve all prior state it changes, log command failures, and consume OpenConnect's standard environment. It still cannot implement Fortinet `<split-dns>` until OpenConnect exports those values. **PLAUSIBLE**

## 6. Logging and diagnostics

### Current state

OpenConnect defaults to informational logging. `-v` can be repeated: one `-v` enables debug-level output and `-vv` reaches trace-level output in the usual CLI mapping. The installed `vpnc-script` documents `LOG_LEVEL` as INFO=1, DEBUG=2, TRACE=3. **CONFIRMED**

The current normal log has no `-v`, which is the right noise level for daily use and already includes many useful Fortinet configuration and transport messages. **CONFIRMED**

### Risk / opportunity

The current error keyword search cannot reliably separate auth stages, transport fallback, server reconnect policy, and DNS application. A one-attempt debug log would make those distinctions much easier. **CONFIRMED**

`--dump-http-traffic` is not appropriate for a hobbyist-shareable diagnostic: it includes HTTP requests and response bodies and can expose cookies, challenge fields, usernames, topology, and other sensitive data. Simple regular-expression redaction is not a sufficient safety boundary for arbitrary HTTP bodies. **CONFIRMED**

Even ordinary `-v` logs can contain username, gateway, internal IPs/routes/DNS names, realm, certificate identity, and server details. A report must be private by default and should clearly list what was redacted. **CONFIRMED**

### Recommendation

Keep normal startup unchanged except for `--non-inter`. Add a separate `diagnose` mode that performs exactly one foreground connection attempt with:

```text
-v --timestamp --non-inter
```

Do not add `-vv` or `--dump-http-traffic` by default. **CONFIRMED**

The mode should write a mode-600 raw log privately, derive a separate redacted report, and retain the raw file locally rather than claiming irreversible safe redaction. Redact at least username, cookies, password/token fields if ever present, internal/public IP addresses, DNS suffixes, and certificate fingerprints. Include OpenConnect/GnuTLS versions, selected realm evidence, DTLS/TLS result, reconnect-policy lines, pushed route/DNS summaries, `scutil --dns`, and route/interface state. **PLAUSIBLE**

Because a connection attempt consumes a live TOTP and may alter routes/DNS, this should be `auckland-vpn diagnose`, not part of the read-only `doctor` command. `doctor` can inspect and summarize an existing diagnostic. **CONFIRMED**

## 7. Version sensitivity

### Current state

The installed version is OpenConnect 9.21 with GnuTLS 3.8.13 and DTLS/Fortinet/TOTP support. **CONFIRMED**

Relevant milestones:

- 8.20 introduced Fortinet PPP protocol support, initially TLS-oriented. **CONFIRMED**
- 9.00 integrated native PPP infrastructure used by Fortinet and supplies `VPNPID`/structured log level to current `vpnc-script`. **CONFIRMED**
- 9.10 fixed repeated Fortinet-cookie crashes, added Fortinet dual stack and FTM push, and improved several protocol parsers. **CONFIRMED**
- 9.20 added `otpauth://` HOTP/TOTP URI support and preserved the full server URL path through authentication. **CONFIRMED**
- 9.21 accepts base32 token secrets without trailing `=` padding. This directly improves the setup flow's raw-base32 support. **CONFIRMED**

`--pid-file` support is not the meaningful minimum for Fortinet quality: although the wrapper checks it as a process-control feature, Fortinet itself arrived in 8.20 and the current PPP implementation is a 9.x capability. **CONFIRMED**

### Risk / opportunity

A nominal “v8+” requirement is misleading: some v8 releases may expose `--pid-file` but lack Fortinet entirely, and 8.20 lacks later Fortinet fixes and current URI behavior. **CONFIRMED**

9.21 does not resolve the major Fortinet limitations in this audit: reconnect remains server-dependent and dedicated Fortinet split-DNS remains unimplemented. **CONFIRMED**

### Recommendation

Require OpenConnect 9.21 or newer for this wrapper, not merely detection of `--pid-file`:

```text
openconnect --version  # parse and require >= 9.21
```

Also retain capability checks for `--protocol=fortinet`, `--token-mode`, `--token-secret`, `--non-inter`, and `--pid-file` so an unusual vendor build fails clearly. **CONFIRMED**

Do not rely on the unreleased `--tcp-keepalive` option until it ships in a tagged Homebrew version and its Fortinet behavior is verified. **CONFIRMED**

## Recommended production invocation

The minimal recommended change is `--non-inter`; everything else should remain on negotiated defaults:

```text
openconnect \
  --protocol=fortinet \
  --user="$VPN_USER" \
  --passwd-on-stdin \
  --non-inter \
  --token-mode=totp \
  --token-secret="@$TOKEN_SECRET" \
  --reconnect-timeout=300 \
  --background \
  --pid-file=/private/etc/auckland-vpn/vpn.pid \
  --script=/opt/homebrew/etc/vpnc/vpnc-script \
  connectvpn.auckland.ac.nz/client
```

`--reconnect-timeout=300` may remain as explicit documentation even though it equals the default. Do not add `--authgroup`, `--no-dtls`, cipher restrictions, compression, forced DPD, or MTU overrides without diagnostic evidence. **CONFIRMED**

## Sources inspected

- Repository `auckland-vpn` and `README.md`.
- Installed `openconnect --version`, `openconnect --help`, and `openconnect(8)` for v9.21.
- OpenConnect 9.21 `fortinet.c` implementation.
- Official OpenConnect Fortinet protocol page and release changelog.
- Installed Homebrew `/opt/homebrew/etc/vpnc/vpnc-script`.
- Homebrew metadata for OpenConnect, GnuTLS, and `ca-certificates`.
