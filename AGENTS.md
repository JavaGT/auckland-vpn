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

Local: `tests/run-tests.sh` (requires ShellCheck: `brew install shellcheck`).
Focused iteration: `tests/run-tests.sh monitor` runs only tests whose names
match the given substrings; no arguments runs the full suite (what CI runs).
CI: GitHub Actions `tests` workflow. Privileged paths are tested through the
wrapper-only seams `AUCKLAND_VPN_HELPER_BIN` / `AUCKLAND_VPN_SUDO_BIN`, never
by patching the helper (see `docs/consults/test-architecture.md`). Design
consults live in `docs/consults/` (reliability, test architecture,
openconnect audit).

## Agent hygiene

- Pain journal: `~/.config/opencode/pain-journals/auckland-vpn.md` — when
  tooling/config/process friction costs you time, append one line there
  without stopping your task work.
- README.md is the full behaviour reference (commands, flags, limits);
  AGENTS.md holds constraints, README holds what the tool does.
- Prior automation findings live in-repo: `docs/reports/` (2026-09-10 wave)
  and `artifacts/` (`reports/` + `automation-receipts/`). Check these and the
  open `[quick-scan]` / `[config-review]` tracker issues before re-deriving
  a known finding.
