# quick-scan — 2026-09-15 0930 wave (auckland-vpn)

Scope: bounded by the finite execution profile (50 min, 3-child cap). Hotspots
from `git log --oneline` since 2026-09-01 were cross-checked against the
2026-09-14 anti-re-derivation lists (artifacts/reports/2026-09-14/) and the 27
open tracker issues before scanning; known findings were not re-derived.

## Findings

1. **Strong → fixed and closed this wave — #45.** `load_config` whitelisted
   `[:space:]` in its acceptance class (auckland-vpn:118), so
   `VPN_USER=alice bob` was silently accepted while the die text on
   auckland-vpn:119 promises letters/digits/@._- only. Fixed in 343c212
   (class tightened; trimming still handles edges), regression test
   `test_config_rejects_internal_whitespace` added (tests/run-tests.sh:236).
   Focused check 3/3, full suite 22/22, hostile review APPROVED with an
   empirical parent-commit diff. #45 closed on that evidence.
2. **Speculative → ticketed (#62, evaluate-framed).** A world-writable
   directory is live on this machine's PATH right now (ruby warning:
   "Insecure world writable dir /Users/server/.local in PATH, mode 040777",
   observed 2026-09-15 during this wave's YAML check). The helper already
   treats PATH as hostile (env -i, /usr/bin-qualified calls, cf. #55), but
   wrapper-side `doctor` never inspects PATH hygiene. #62 asks whether doctor
   should flag world-writable PATH entries; implementation explicitly not the
   todo.
3. **Evidence appended to existing tickets (no new ticket):**
   - #48: tests.yml itself parses clean (ruby YAML safe_load: name `tests`,
     one job `tests`) but `gh workflow list` / `gh run list` on origin still
     return empty — "CI green" remains unverifiable; blocker unchanged (#37).

## Checked and consistent (anti-re-derivation list)

- YAML surface: the repo's only workflow file parses with no warnings; no
  duplicate job keys, name matches README's `tests` claim locally.
- #45 fix itself: no documented config form regresses — plain, double-quoted,
  single-quoted, trailing-whitespace and CRLF lines all still load as before
  (reviewer-verified against the parent commit, including quote-stripping
  order — no whitespace smuggling path remains).
- 2026-09-14 anti-list items (usage/dispatch wiring, `wait_until_vpn_gone`
  best-effort behaviour, generate_helper duplication, wrapper-only test
  seams) were not re-walked; nothing in today's diffs touches them.
- Pain journal live: header + mined-history intact, no unmined entries
  (ambient pass; one honest new line appended for this wave's missing-pyyaml
  stumble).

## What I did not look at

- Monitor state machine, helper internals, installer/uid-gid paths — owned by
  #46, #22, #23, #28, #43, #44, #47, #55, #56.
- Keychain/secret plumbing — #53, #27 own it.
- Live network/privileged behaviour — manual-only per
  docs/consults/test-architecture.md.
- Session transcripts beyond the metadata sample (config-review report covers
  the bounded sample).
- Full opencode.json ↔ MODEL-ROUTING.md consistency sweep — #61 owns the
  evaluate question; only the two routes used this wave were re-verified.
