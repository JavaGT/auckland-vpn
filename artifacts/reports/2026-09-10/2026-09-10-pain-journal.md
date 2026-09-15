# Pain-journal mining report — auckland-vpn (2026-09-10)

Playbook agent run: make the standing pain-journal instruction live for this
repo, mine existing journals for prior auckland-vpn friction, mine
session-observable friction, ticket findings. Ambient run — no friction was
manufactured; all commands used were read-only or additive.

## Action taken: journal made live

- Created `~/.config/opencode/pain-journals/auckland-vpn.md` (did not exist;
  verified by coordinator recon and re-verified this session) with a short
  header documenting the append format (`- YYYY-MM-DD area one line`) so
  future agents can log without stopping.
- Sibling journals confirmed present: ccsearch.md, rapid-feedback.md,
  scope.md, scope-mined-2026-09-10.md, workbench.md.

## Prior-capture sweep (sibling journals)

Method: `rg -i 'auckland-?vpn'` then a broader pass for
`openconnect|fortinet|totp|vpnc|\bvpn\b` across `~/.config/opencode/pain-journals/`.

Result: **zero** auckland-vpn friction captured anywhere, ever. The single
VPN-term hit (`scope.md:97`, TOTP "enroll 409" test) belongs to a different
codebase (`src/lib/utils/user-error.ts`); not this repo.

Edit safety: mtimes checked against a 1h-fresh and 24h-stale rule.
`scope.md` was modified ~6 minutes before the sweep (active writer — left
untouched); all other files were 1.3–11.3h old. **No file was >24h stale, so
no mined-line removal was performed anywhere** — per the run contract, mined
lines would have been copied here verbatim; there were none to copy.

## Session-observable friction mined

### Theme 1 (Strong, repetition: hit every agent working here) — the journal gap itself

The standing instruction cost this wave a discovery pass and has silently
captured nothing for this repo to date: the instruction lives only at user
level, and nothing repo-side points to it.

- **Root cause:** the "Pain journal" instruction exists only in
  `~/.zcode/AGENTS.md`; `/Users/server/Development/auckland-vpn/AGENTS.md`
  (read in full, 25 lines — design notes + testing pointers, lines 1–25) has
  no pointer, and the per-repo journal file did not exist to receive entries.
  Consequence observed this session: five sibling repos have journals; this
  repo had zero entries and zero mentions across all journals.
- **Fix (partially delivered):** journal file created this session with a
  format header. Remaining half: a one-line pointer in the repo AGENTS.md —
  repo file I do not own, so ticketed.
- **Ticket:** [#17 — "[pain-journal] Pain-journal practice not discoverable
  from this repo — add AGENTS.md pointer"](https://github.com/JavaGT/auckland-vpn/issues/17)
  — suggested owner: config-review lane, AGENTS.md. Contains evidence, smallest
  fix (exact line to add), acceptance checks, and the decision question.

No other themes: git, `gh`, and `rg` all worked first-try this session; nothing
else met the bar of real friction, and none was manufactured.

## Ticket index

| Issue | Theme | Strength | Suggested owner |
|---|---|---|---|
| [#17](https://github.com/JavaGT/auckland-vpn/issues/17) | Journal not discoverable from repo | Strong | config-review lane (AGENTS.md) |

Cross-reference: #17 links back to this report
(`artifacts/reports/2026-09-10/2026-09-10-pain-journal.md`,
moved from `docs/reports/` in #58). Open at report time: #1
(openfortivpn performance — unrelated, not touched). No tickets were closed.
