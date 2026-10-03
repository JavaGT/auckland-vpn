# quick-scan + config-review — 2026-09-16 0930 wave (auckland-vpn)

Scope: bounded by the finite execution profile (50 min box, ≤3 children).
Hotspots from `git log --oneline` since 2026-09-02; the only unscanned code
since the 2026-09-15 scans was 99c06e3 (review-round FIX-FIRST fixes for
#63/#64). Known findings were not re-derived (30 open issues cross-checked;
anti-lists in artifacts/reports/2026-09-14/ and 2026-09-15/ honoured).
All three playbooks ran; there were no code changes this wave, so no hostile
review round was due (route policy: one round per completed scoped commit).

## Findings

1. **No new code findings.** The frontier is clean:
   - 99c06e3 claims verified in code: README's per-source username paragraph
     matches the implementation (config trim + quote-pair strip at
     auckland-vpn:116-135; prompt trim only at auckland-vpn:1030-1036; env
     verbatim + loud validation at auckland-vpn:218-220; conflicting
     duplicate rejection at auckland-vpn:132-134). The `username_is_valid`
     empty-string fix is present (auckland-vpn:94).
   - Near-miss investigated and cleared: `monitor_heal`'s stop phase only
     assigns `stop_rc` on failure (auckland-vpn:1685), which looked like a
     stale-value bug until the declaration `local pass token stop_rc=0`
     (auckland-vpn:1671) — initialized correctly, no ticket.
   - `cmd_doctor` walk (auckland-vpn:1837-1900): every check names the exact
     fix; sudoers check tests both exact invocations; write-test cleans up
     after itself. Consistent with its doc comment.
2. **Evaluate ticket resolved → #65 closed.** Unifying username ingestion
   semantics (config trims+strips quotes, prompt trims only, env verbatim)
   was evaluated and **rejected**: all three paths already share the safety
   property that matters (`username_is_valid` fixed class); the differing
   pre-validation normalization is each source's correct behavior (loud
   failure over silent credential transformation for the env var), and the
   documentation drift that motivated the ticket was fixed the safer way in
   99c06e3. Full verdict with file:line evidence is on the ticket.
3. **Evidence appended → #60.** The 2026-09-16 scheduler again supplied no
   run_id/attempt (receipt named `unsupplied-20260916T0930-attempt-1`); every
   wave since the receipt schema activated has needed the fallback. Ticket
   stays open.

## config-review (playbook section)

- **#21 verification (due 2026-09-17) — run early, ticket closed.** Checks
  1–3 PASS (AGENTS.md pointers complete; pain journal demonstrably live from
  multiple agents across five dates; both consults carry dated status
  addenda at docs/consults/reliability.md:3,10,15 and
  docs/consults/test-architecture.md:3,160). Check 4 (CI green) remains
  blocked by #48/#37 — mapped to the already-open tickets per #21's own rule.
- **#60 recurrence evidence appended** (see finding 3).
- **Session sample:** bounded `opencode2 api get /api/session` sample showed
  recent children healthy (succeeded outcomes, no stalls); nothing
  auckland-vpn-specific to mine. No ticket.
- Standing friction fixes verified in passing: the zsh guard rules and the
  long-read verify rule in AGENTS.md are present and were applied this wave
  (the `stop_rc` near-miss was re-verified with grep/sed before being
  dismissed, exactly as the rule requires).

## pain-journal (playbook section)

- Ambient pass only: standing instruction live (header + format intact),
  **zero unmined entries** — the 09-15 pyyaml line was mined to #20 evidence
  and pruned on schedule. No friction manufactured; no new line warranted
  this wave (no tooling cost was incurred).

## Checked and consistent (anti-re-derivation list)

- YAML surface unchanged since 2026-09-15 scan (tests.yml still the only
  workflow file; parses clean).
- Full test suite 24/24 on 3c3c9bc this wave (focused check; log
  /tmp/wave-tests.log).
- 2026-09-15 anti-list items (usage/dispatch wiring, monitor state machine,
  helper internals, installer paths, Keychain plumbing) not re-walked;
  owned by #46, #22, #23, #28, #29, #43, #44, #47, #53, #55, #56.
- Route policy re-verified live against ~/.config/opencode/MODEL-ROUTING.md
  before any dispatch decision (verified_at stale per #54; luna and
  deepseek-flash routes match; no dispatch needed this wave).

## What I did not look at

- Monitor circuit breaker internals, helper stop path, installer/uid-gid —
  owned by #22, #23, #28, #46, #47, #56.
- Keychain/secret plumbing — #53 owns the evaluate question.
- Fork reconciliation / push lineage — #37 owns it; this wave commits
  locally like its predecessors.
- Full opencode.json ↔ MODEL-ROUTING.md consistency sweep — #61 owns it;
  only the routes relevant to this wave were re-verified.
