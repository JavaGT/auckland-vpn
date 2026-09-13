# quick-scan — 2026-09-14 0930 wave (auckland-vpn)

Scope: last ~2 weeks of hotspots (28 commits since 2026-08-31). Hot files by
touch count: `auckland-vpn` (4x), `AGENTS.md` (6x), README.md,
`tests/run-tests.sh`, both consult docs, reports/receipts. Navigation docs
(AGENTS.md, prior reports, open tracker issues #21–#58) read first; known
findings were not re-derived.

## Findings (ranked strength x leverage)

1. **Worth exploring → fixed this wave — README Testing omits the suite's
   only iteration affordance.** AGENTS.md:24-26 documents
   `tests/run-tests.sh monitor` (substring filtering); README.md's Testing
   section showed only the full run, though README is declared the full
   behaviour reference (AGENTS.md:38-39). Interface is real:
   tests/run-tests.sh:895 (`Usage: ... [substring ...]`), :918 (selected
   summary). Ticketed as #59 and fixed in this wave's commit.
2. **Worth exploring → ticketed (#60) — scheduler never supplies
   run_id/attempt.** Every receipt on disk (2026-09-13 x2, 2026-09-14 x1)
   uses the self-invented `unsupplied-` fallback while the schema forbids
   inventing IDs. Config-review finding; evidence in
   config-review.md (this directory) and #60.
3. **Speculative → ticketed (#61) — MODEL-ROUTING.md ↔ opencode.json
   duplication** has no derived consistency check; no contradiction observed
   today. Config-review finding; evaluate-framed per #61.
4. **Evidence added to existing tickets (no new ticket):**
   - #54: 4th consecutive run paying the stale-inline-policy re-verification
     cost (verified_at 2026-09-13T02:08:05Z already stale at 09:31 dispatch).
   - #58: config-review child wrote its report to the wrong tree
     (artifacts/reports/ root instead of the dated subdirectory) — live
     instance of the split's confusion; moved to
     artifacts/reports/2026-09-14/config-review.md.
   - #48: `gh` workflow lookup again returned no `tests` workflow; README.md
     CI claim stays unverifiable until #37 reconciles the fork split.

## Checked and consistent (anti-re-derivation list)

- Top-level `usage()` vs dispatch vs README "Daily use": all 11 subcommands
  documented and wired (auckland-vpn:1993-2042; README:79-98).
- #42 fix verified in code: `wait_until_vpn_gone` (auckland-vpn:371-388) is
  best-effort — 10s wait, one helper `stop`, `|| true`; README keeps no
  "confirm gone" promise (grep clean).
- Duplicate `die`/`usage`/`cmd_start`/`cmd_stop` definitions are
  `generate_helper` heredoc/printf content (auckland-vpn:389-755) — by
  design, not drift.
- Wrapper-only test seams documented in AGENTS.md exist as claimed
  (tests/run-tests.sh:804-821); focused-run summary line matches AGENTS.md.
- `monitor [--once]` wired (auckland-vpn:1754, usage:2004); `log -f` matches
  docs (auckland-vpn:956-970).
- Installed `/opt/homebrew/bin/auckland-vpn` still differs from the repo
  build (`diff -q` rc=1) — #33 remains valid as filed.

## What I did not look at

- Monitor state-machine internals (auckland-vpn:1548-1632) and
  `monitor_heal` privileged branches — covered by #46, #22, #43, #44.
- Helper stop path and sudoers generation — covered by #28, #23, #47, #55.
- Keychain/secret plumbing — #53, #27 own it.
- Live network/privileged behavior — manual-only per
  docs/consults/test-architecture.md.
- Full session transcripts — config-review sampled metadata only.
