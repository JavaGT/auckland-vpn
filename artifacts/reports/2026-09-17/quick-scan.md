# quick-scan — 2026-09-17 (auckland-vpn)

Read-only unattended scan. Hotspots: commits since 2026-09-01, concentrated on
`auckland-vpn` (9f5aefc + 063278a PATH-hygiene/#69; 1fc97c1 + 343c212 + 99c06e3
username validation/#63/#64/#45), `tests/run-tests.sh`, README.md, consults.
AGENTS.md/README.md read first; known-open anti-list (30 issues) and prior
scans (artifacts/reports/2026-09-14/15/16) honoured — no re-derivations.
All candidate findings re-verified with sed/grep at exact lines; two were
additionally reproduced live in /tmp sandboxes (no repo mutations).

## Findings (ranked strength x leverage)

### 1. Worth-exploring — group-writable PATH-hygiene branch has zero committed test coverage, and its known cosmetic residual is untracked

`cmd_doctor`'s PATH walk has two mode branches: world-writable
(auckland-vpn:1956-1968, canonical `pwd -P` reporting) and group-writable
(auckland-vpn:1969-1972, gid-80 filter, raw `$p` reporting). The committed
suite exercises only the world-writable branch, the empty-entry WARN, the
exemption helper directly, and a world-writable `../`-symlink case
(tests/run-tests.sh:810-869, test_doctor_warns_on_writable_path_entries);
`grep 'group-writable|775|gid|:80' tests/run-tests.sh` finds nothing. The
branch works (verified live: a mode-775 gid-0 ancestor produces
`WARN  PATH entry ... group-writable component: ... (mode 775, group not admin)`)
but its only verification ever was the manual mode matrix in
artifacts/reports/2026-09-16/review-69-path-hygiene.md:67 — not committed, so
a future regression in `*[2367]?)` or the `[ "$pgid" = "80" ]` filter would
pass the suite silently. Related: the review's N3 residual — group-writable
findings still print the un-normalised `$p` while world-writable prints
canonical `$rn` (review artifact line 84, "Residual (cosmetic, not a return of
N3)") — was consciously left but never ticketed, and #69 is now closed, so the
residual lives only in a report artifact. Fix shape: one fixture (775 dir,
gid != 80) asserting the WARN text, plus fold the canonical-path residual into
the same ticket (or ticket it separately if deliberately WONTFIX).

### 2. Worth-exploring — env-vs-config VPN_USER conflict is misreported as "duplicate conflicting VPN_USER lines"

The duplicate check (auckland-vpn:132-134) compares the incoming config value
against whatever `VPN_USER` currently holds — which is seeded from the
environment at auckland-vpn:218 before `load_config` at :222. So with
`VPN_USER=alice` in the environment and `VPN_USER=bob` in the config, the die
is `"$CONFIG_FILE:1: duplicate conflicting VPN_USER lines."` — reproduced live.
There is only one line in the file; the message names a nonexistent second
config line and, unlike every sibling message, does not say where the other
value came from. Behavior (conflict is fatal rather than env-wins) seems right
and is arguably safest, but it is untested
(test_config_rejects_conflicting_users, tests/run-tests.sh:225-236, passes
`VPN_USER=''`; test_env_username_rejected:247-255 only covers invalid chars)
and undocumented — README.md:48-50 describes only "Two conflicting VPN_USER
lines in the config file". Fix shape: distinguish the message
("VPN_USER in the environment conflicts with $CONFIG_FILE:$n"), add the
env-vs-file test, and give README a clause on the precedence.

### 3. Speculative — the new advisory block resolves `tr` through the very PATH it audits

The PATH-hygiene block deliberately qualifies every binary it runs —
`/usr/bin/stat`, `/usr/bin/readlink`, `/usr/bin/dirname`, `/bin/pwd` — but
feeds its entry list through an unqualified `tr` (auckland-vpn:1994,
`printf '%s\n' "$PATH" | tr ':' '\n'`). A PATH-planted `tr` could merge/split
entries and suppress every finding of a check whose entire purpose is to
detect a hostile PATH. The block comment (:1936) assigns unqualified-call
hardening to #55's lane, so this is not new territory — but it is a NEW
unqualified call added inside security-sensitive code, and should be on #55's
list when that hardening lands so it is not forgotten as "already fine".

### 4. Speculative — empty/unset PATH prints no PATH-hygiene line at all

The whole block is wrapped in `if [ -n "${PATH:-}" ]` with no else
(auckland-vpn:1940, closing at :2003), so `PATH=""` yields neither OK nor
WARN nor INFO — the only doctor check that can print nothing. Edge case (an
empty PATH is pathological), but empty PATH is exactly when unqualified
lookups fall back to the shell's default path, i.e. when the advisory is
most blind. An INFO line ("PATH empty — hygiene check skipped") would keep
doctor's one-line-per-check shape.

### 5. Speculative (doc nit) — README understates the advisory WARN classes

README.md:98-100 describes the doctor advisory WARNs as covering
"group/world-writable PATH components" only; the same commit (9f5aefc) also
added the empty-PATH-entry WARN (auckland-vpn:1942-1948), which is a different
class and is not mentioned. One-line README touch-up whenever doctor output is
next edited.

## Verified clean (investigated, no ticket)

- `path_hygiene_sip_exempt` (auckland-vpn:312-318): prefix-sibling lookalikes
  correctly rejected (`/System/Volumes/Preboot/Cryptexes*` glob cannot match
  `CryptexesEvil`); non-root ownership rejected; exemption surfaces via the
  INFO line at :1995-1997. Matches the review artifact's claims.
- Write-bit rules match `path_is_trusted` as the comment claims (other-write
  always bad, group-write only gid 80; ownership deliberately unchecked) —
  confirmed against path_is_trusted at auckland-vpn:564-592.
- Mode-glob correctness: `%Lp` yields 3-digit modes on this macOS (verified:
  755, 777); `*[2367]` / `*[2367]?)` branch selection is correct, with
  world-write intentionally shadowing group-write (world-write implies it).
- The walk does cover symlink-parent ancestors (unnormalised `..` paths keep
  `$box/sub` in the chain) — the ..-littered spelling was the defect, the
  coverage is a feature.
- README per-source username paragraph (README.md:44-50) matches the code:
  config trim + quote-pair strip (auckland-vpn:116-128), prompt trim only
  (:1046-1051), env verbatim (:218-221); `username_is_valid` empty-string fix
  present (:93).
- Focused suite green: `tests/run-tests.sh doctor` → 2 passed (of 25 selected);
  matching interface per AGENTS.md works (`doctor_path` correctly matches
  nothing and says so).
- Consults (reliability, test-architecture) carry no claims contradicted by
  the new code.

## What I did not look at

- `monitor_heal` / `cmd_monitor` internals (known #43/#44/#46/#24 lane).
- `setup-sudo` / installer / helper generation beyond the 99c06e3 diff
  (known #47; sudo-liveness caveats in AGENTS.md respected — no `sudo -n`
  probes were run).
- Keychain/password plumbing and `-w` argv exposure (known #53).
- CI workflow / hermeticity beyond the pinned-PATH fixture (known #48/#35).
- docs/consults/openconnect-audit.md contents; artifacts/ prior reports beyond
  overlap cross-checks.
- The bulk of tests/run-tests.sh outside the new/related tests (~700 lines).
- Anything requiring network, sudo, or mutating git/gh commands (out of scope
  for this run).
