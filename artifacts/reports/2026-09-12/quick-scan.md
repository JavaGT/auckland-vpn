# Quick-scan report — 2026-09-12 (0930 automation wave)

Scope: drift/friction pass over last-2-weeks hotspots (`auckland-vpn` script,
`tests/run-tests.sh`, README, consult docs) plus the areas the 2026-09-11 scan
explicitly declared unexamined (Keychain invocation surface, consult bodies,
workflow YAML). Prior findings #22–#52 taken as read, not re-derived.

## Findings

1. **Speculative — ticketed as #53**: `cmd_setup` stores the Keychain password
   via `security add-generic-password -w "$PASS"` (`auckland-vpn:1035`), so the
   password rides argv and is visible in the local process table for the
   duration of the `security` call. Low severity (single-user host, one-shot
   call); todo is evaluate stdin-mode (`security -i`) vs a dated accepted-risk
   addendum in `docs/consults/openconnect-audit.md`. Verified new: grep across
   the audit doc and all prior reports found no prior mention.

## Checked, no drift found

- README stop/restart wording matches the shipped best-effort wait
  (README.md:86,141 vs `auckland-vpn:362-375`) — the #42 docs truth-up landed
  consistently.
- Config parser: duplicate *conflicting* `VPN_USER` lines die with line numbers
  (`auckland-vpn:117-119`); identical duplicates are inert, and setup's save
  path only writes when `VPN_USER` is empty (`auckland-vpn:1000-1008`), so it
  cannot create them.
- `.github/workflows/tests.yml` parses clean (ruby `YAML.safe_load`) — the
  local YAML surface is currently valid; the CI-never-ran state remains #48/#37.
- Pain journal: no unmined entries (last mined 2026-09-11, #41). One new line
  appended this run: inline route-policy `verified_at` is past its 24 h window
  by run time; the local `MODEL-ROUTING.md` table resolves it.

## What I did not look at

- macOS-version sensitivity of `stat -f`/`mktemp` (carried over from the
  2026-09-11 unexamined list);
- `docs/consults/reliability.md` body claims beyond what #22/#23/#28/#43/#44/#46
  already cover;
- origin-divergence reconciliation (#37) and CI activation (#48);
- real privileged behavior — manual-only per the test-architecture consult.
