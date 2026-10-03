# Evaluation: extend the zsh `===` guard to opencode2 children

## Verdict

**WORTH-DOING** — The recurring failure is real and the existing ZCode hook cannot see OpenCode 2 child shell calls. A narrowly scoped shell-level guard is worthwhile, but `~/.zshrc` alone closes the gap only for child shells that actually start zsh as a login/interactive shell; it is not a universal OpenCode enforcement point. Prefer an OpenCode-native pre-shell-command hook if the installed version exposes one; otherwise use a conservative zsh startup/precommand guard and document its coverage.

## Evidence

- The repository explicitly records the scope gap: the ZCode Bash guard covers ZCode calls only, while `opencode2` child sessions are unguarded (`/Users/server/Development/auckland-vpn/AGENTS.md:50-52`).
- The current guard is `/Users/server/.zcode/hooks/bash-guard.mjs`; its header says it is a PreToolUse guard for the Bash tool and fail-open (`:2-5`). It rejects commands matching `echo` followed by bare `===`-style text at command boundaries (`:17-25`), so it cannot protect a separate OpenCode shell surface.
- Ticket #57 and its owner comment document the fourth occurrence: the 2026-09-13 hostile-review child failed on unquoted `echo ===`, despite the written rule being available to the child.
- The existing `~/.zshrc` mitigation is a function wrapper for `rg`, not a general command guard (`/Users/server/.zshrc:15-17`). A direct shell check showed it is loaded by `zsh -lic`, but not by non-login `zsh -c`; therefore sourcing `~/.zshrc` by OpenCode children is conditional, not established for every shell invocation.
- The installed OpenCode CLI is a native executable (`/Users/server/.bun/install/cache/@opencode-ai/cli@0.0.0-bdbb3c055da8c11c@@@1/package.json:3-9`). Its local config enables a plugin (`/Users/server/.config/opencode/opencode.json:326-328`), but contains no documented shell/pre-command guard setting. The executable contains `/bin/sh`, `/usr/bin/zsh`, and related shell paths, but that binary inspection does not prove which path or startup flags a particular child uses.
- False-positive risk is manageable but non-zero: rejecting only an unquoted `echo` argument beginning with `===` mirrors the current hook and targets the known zsh expansion hazard. A broad `echo` replacement or an unconditional `preexec` denial could break legitimate demonstrations/tests that intentionally print `===`; keep the matcher boundary-aware and provide a bypass.

## Proposed change sketch

**Effort: S. Risk: low-to-medium.** First verify the installed OpenCode plugin API for a before-shell/tool-execution hook; if available, port the existing fail-open matcher there. If not, add a small, boundary-aware guard to the zsh startup path used by child shells (not merely an interactive-only alias), with an explicit bypass such as `command echo` or an environment toggle, and test login and non-login zsh invocation separately. Do not replace the existing ZCode hook: the two surfaces need separate coverage.

## What I did not check

- I did not execute an OpenCode child shell or alter OpenCode configuration, so the exact child shell executable and flags remain unverified.
- I did not inspect OpenCode source or external documentation for the complete plugin hook API.
- I did not test a proposed guard against a corpus of legitimate `echo ===` uses.
- I did not modify, commit, or comment on any repository or GitHub issue.
