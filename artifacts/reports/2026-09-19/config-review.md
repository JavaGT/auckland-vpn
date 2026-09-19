# config-review — 2026-09-19 (auckland-vpn, manual catch-up)

Scope: agent-facing configuration and process friction for this repo's
automation waves. Edits are the deliverable where evidence supports them; this
wave the evidence produced tracker evidence-comments plus one deferral
decision, not config edits (the affected config lives outside this workspace).

## Findings and actions

### 1. Inline route policy stale at run time → all reviewer/consultant dispatches deferred (recurrence → #54)

Policy 2026-09-13.2 (verified_at 2026-09-13T02:08:05Z, stale_after 86400s) was
~6 days stale at run time. Per the policy's classify-and-defer rule and
AGENTS.md's #54 pointer, no `opencode2 run` was dispatched; the wave's hostile
review round for 95c4bdc is deferred to the next wave with a concrete
checkpoint (below). Evidence comment posted on #54.

### 2. The policy's grunt route references an absent provider key → evidence → #66

`providers` in ~/.config/opencode/opencode.json = deepseek,
opencode-account-1..4, openrouter — no `openai` key — while the global default
`model` is `openai/gpt-5.6-luna` and the inline policy's grunt route resolves
against it. MODEL-ROUTING.md's 2026-09-19 note (check:agent-configuration
#4010) flags the same for the sol profile. Comment posted on #66 strengthening
its consistency-check ask (fail loudly when a documented route or the default
model references an absent provider). The file itself is outside this
workspace, so the fix is ticketed, not edited.

### 3. pain-journal — no-finding

Standing instruction live (AGENTS.md:35-37; journal header documents format +
prune history). Journal has no unmined entries: 09-17 batch dispositioned to
#70/#54 and pruned 09-17. Nothing mined, nothing pruned, no manufactured
friction logged.

### 4. #82 implemented — REALM warning made self-contained (801613a)

Claimed #82 (Account-2, this morning) and applied the "inline the actionable
sentence" branch: user output now carries the audit-verified mechanism instead
of a repo path installed users do not have. The ticket's owner-decision
framing is recorded on the ticket; the chosen branch is a superset of the
alternative and trivially revertable at review. Suites green (diagnose 1/1,
full 26/26).

## Deferred work and exact next action

- Hostile review of 95c4bdc (#83) and 801613a (#82) — blocked only by route
  verification, not by evidence. Next wave: re-verify the exact
  `--agent`/`--model` pairs against ~/.config/opencode/MODEL-ROUTING.md (fresh
  as of 2026-09-19 11:31), dispatch one reviewer over both commits, reconcile
  the verdicts, and close #83/#82 on APPROVED / route FIX-FIRST fixes back to
  the tickets.
- #66/#54 remain open (evaluate lanes; owner-visible, tracked).
