# auckland-vpn — agent notes

Bash wrapper around `openconnect --protocol=fortinet` for the University of
Auckland VPN: openconnect generates the TOTP code itself, reconnects
automatically, and DNS is handled by the Homebrew `vpnc-script`. Installed as
`/opt/homebrew/bin/auckland-vpn`.

## Design decisions that look wrong but are deliberate

- **No certificate pinning** — the university gateway cert rotates, so pinning
  would break on rotation. Trust the system CAs.
- **Config file is parsed, never executed** — only blank lines, `#comments`,
  and `VPN_USER=<username>` lines are accepted. Preserve this property in any
  refactor.
- **Privilege stays narrow**: helper/sudoers changes must preserve the
  restricted-sudoers model. Non-interactive sudo probes (`sudo -n true`) fail
  under that design — never use them as liveness checks. Get a hostile review
  of any privilege-path change against `docs/consults/openconnect-audit.md`.
- Credentials and TOTP secrets never enter the repo or session logs.

## Testing

Local: `tests/run-tests.sh`. CI: GitHub Actions `tests` workflow. Design
consults live in `docs/consults/` (reliability, test architecture).
