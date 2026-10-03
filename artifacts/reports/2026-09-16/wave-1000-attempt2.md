# Wave 1000 attempt 2 report — 2026-09-16 (auckland-vpn)

Scope: bounded by the finite execution profile (50 min box, ≤3 children,
cutoff 45 min). Started 10:02:08+12:00. This is the **on-time fire of the
1000 slot**; the slot already ran early at 09:23 (attempt 1, committed
32bf852) — the same slot/double-execution pattern #67 documents for the 0930
slot. Reconciliation before admission: HEAD 476add7, clean tree, nothing
in-flight from other lanes (~2 min).

## Admission decision

Re-running plain quick-scan/config-review on the unchanged code frontier
(99c06e3, verified by three waves today) would re-derive known findings —
banned. Admitted instead, in stable order, per the 0930-attempt-2 report's
named checkpoint ("#68/#69 implementation — next wave, claim first"):

- **quick-scan → #69 implementation** (doctor PATH-hygiene check; verdict
  WORTH-DOING, live 777 PATH ancestor verified in `eval-62-doctor-path.md`).
- **config-review → #60/#67 recurrence evidence** from this fire itself.
- **pain-journal → prune the mined 2026-09-16 entry** (traced to #67).
- Deferred with checkpoint: **#68** — first step is a bounded verification
  whether the installed OpenCode build exposes a pre-shell hook (the eval
  report's preferred mechanism if available); the zsh-guard fallback and the
  global-config surface make it a poor fit for this wave's remaining box.
  **#66** stays owner-gated (delete-vs-repoint on global config).

## Findings

1. **#69 implemented: `9f5aefc`.** `cmd_doctor` now walks every PATH entry's
   ancestor chain — symlinks followed with a 16-hop cap, absolute
   `/usr/bin/stat`, modes read as `%Lp` — and emits advisory **WARN** lines
   for world-writable components and group-writable ones outside the admin
   group (gid 80), the exact rules `path_is_trusted` enforces for privileged
   launches. Warn-only: WARNs never increment `fixes` and never change the
   exit code; hardening the wrapper's unqualified PATH calls remains #55's
   lane. Output is capped at the first 5 findings plus a summary count;
   empty PATH entries (current directory) are warned. README doctor line and
   the `cmd_doctor` header contract updated.
   - Focused fixture `test_doctor_warns_on_writable_path_entries` pins PATH
     explicitly (#35 hermeticity): world-writable ancestor → WARN and no
     `OK PATH hygiene` line; repaired ancestor → OK; empty entry → WARN.
   - Focused checks: suite **25/25** (`tests/run-tests.sh`, shellcheck via
     `test_static_wrapper`), log `/tmp/full-suite-1000wave.log`.
   - Live evidence: `bash auckland-vpn doctor` surfaces the original #62
     finding — `WARN PATH entry /Users/server/.local/bin has a world-writable
     component: /Users/server/.local (mode 777)` — plus a second, Apple-
     shipped one: `/System/Volumes/Preboot/Cryptexes` is root-owned 777, so
     the `/System/Cryptexes/App/usr/bin` PATH entry warns on stock macOS.
     That false-positive question is put to the hostile reviewer explicitly.
2. **#60 recurrence appended** (comment): this on-time fire also supplied no
   run_id/attempt; receipt `unsupplied-20260916T1000-attempt-2-...`.
3. **#67 recurrence appended** (comment): 1000 slot double-execution
   confirmed — early 09:23 fire plus the on-time 10:00 fire; same-day
   pattern 0930 fired 09:07+09:30, 1000 fired 09:23+10:00.
4. **No new shell/YAML findings.** Code frontier unchanged since 99c06e3;
   this wave's only code changes are the #69 commits below, validated by the
   25/25 runs. Anti-lists from 09-14/15 and today's reports honoured.
5. **Hostile review of `9f5aefc` (deepseek-v4.1-flash, route rows 33/37
   re-verified live): FIX-FIRST → reconciled in `063278a`.** The check was
   correct on every stated constraint, but emitted a guaranteed false-
   positive WARN on every stock macOS: `/System/Volumes/Preboot/Cryptexes`
   is root:wheel 777 (an ancestor of the stock
   `/System/Cryptexes/App/usr/bin` PATH entry) yet unwritable even to root
   under SIP. Fix: `path_hygiene_sip_exempt` — a one-entry annotated
   allow-list (path under the Cryptexes tree AND root:wheel-owned) that
   skips the component and surfaces the skip as an INFO line; world-
   writable components are now reported by canonical path (`cd` + `pwd -P`,
   also review N3); regression asserts added (4 direct helper cases + a
   `../`-symlink integration case). Suite 25/25 after the fix; live run now
   WARNs on `/Users/server/.local` (the real finding) and INFO-skips the
   cryptex. Reviewer N1 (sandbox-ancestry hermeticity of the "clean" case)
   and N2 (duplicate findings for shared ancestors) accepted as
   wontfix-minor: N1 is the same class #35 tracks and low severity, N2 is
   bounded by the 5-line cap and marginal for an advisory. Confirmation
   round dispatched to the same seat; #69 closes on its verdict.

## pain-journal (playbook section)

- Standing instruction live (header + format intact). The one open entry
  (2026-09-16 scheduler double-fire) was already mined → #67; recurrence
  evidence appended to the ticket this wave and the entry **pruned**, header
  history updated. This wave's own ~2 min reconcile cost is the same #67
  theme — logged on the ticket, not as a new journal line (no manufacture).

## config-review (playbook section)

- Scheduler/config misfire evidence went to #60/#67 (findings 2–3).
- Recent-session mining not re-run: the 0930 wave sampled sessions ~90 min
  earlier and reported healthy; the only sessions since are this fleet's own
  waves. #68 carries the adopted `===`-guard work with a named first step.

## What I did not look at

- Monitor circuit breaker, helper stop path, installer/uid-gid, Keychain
  plumbing, fork reconciliation — owned by #22, #23, #28, #29, #43–47, #53,
  #55, #56 (anti-list honoured).
- #66 (deepseek-hosted-flash delete-vs-repoint) — owner's call, untouched.
- #68 implementation — next wave, first step named in the admission section.
- Full recent-session mining (see config-review section).

## Children and reviews

- Implementation done by the coordinator (the configured generator route owns
  implementation; it is this session): commits `9f5aefc`, `063278a`.
- Review 1: hostile review of `9f5aefc` via `opencode2 run --auto --agent
  deepseek-v4.1-flash --model deepseek/deepseek-flash` (route re-verified
  live against MODEL-ROUTING.md rows 33/37), backgrounded → **FIX-FIRST**
  (`review-69-path-hygiene.md`) → reconciled in `063278a`.
- Review 2 (confirmation, same seat, same route): **SATISFIED** — cryptex
  false positive gone, exemption narrow and correct (lookalike and non-root
  cases still report), N3 pinned by the symlink regression; reviewer agreed
  with the N1/N2 wontfix-minor calls; residual (non-driving): group-write
  branch still prints the un-normalised path. **#69 closed** on this verdict
  with the reconciliation comment.
- Consultants not dispatched: no design candidate on the table for
  cross-evaluation; the change sketch was already settled by the #62
  evaluation.
