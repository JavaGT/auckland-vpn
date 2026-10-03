# Hostile review — commit 9f5aefc: advisory doctor PATH-hygiene check (#69)

- **Commit reviewed:** `9f5aefc` (`doctor: advisory PATH-hygiene check for group/world-writable ancestors (#69)`), HEAD of `main`.
- **Ticket:** #69 (verdict carried from #62, `artifacts/reports/2026-09-16/eval-62-doctor-path.md`).
- **Scope:** the new block inside `cmd_doctor` and its header comment (`auckland-vpn`), `test_doctor_warns_on_writable_path_entries` + registration (`tests/run-tests.sh`), the `doctor` line (`README.md`).
- **Mode:** read-only. No edits to the reviewed code, no git state changes, no `gh` writes. Only this report file was created.
- **Checks reproduced:** `bash tests/run-tests.sh` → `25 passed, 0 failed`; `shellcheck auckland-vpn` → rc 0 (the suite's `test_static_cli` shellchecks `$CLI` at `tests/run-tests.sh:174`, not the test file).

---

## Verdict summary

**FIX-FIRST.** The check is correct, well-bounded, and honours every stated constraint; the live true positive (`/Users/server/.local`, mode 777) is caught. But it also emits a **guaranteed false-positive WARN on every stock macOS**: the `/System/Cryptexes/App/usr/bin` PATH entry has the SIP-protected `.../Preboot/Cryptexes` directory (mode 777, root:wheel) as an ancestor, so `doctor` prints a scary-but-un-actionable WARN on a pristine Mac. That needs a targeted exclusion before this ships as a doctor check.

---

## Open question (must judge): the Cryptexes 777 ancestor

**Finding: false positive — it needs an exclusion; it is not acceptable advisory noise.**

Evidence, all verified at the exact lines/commands:

- `/System/Cryptexes/App/usr/bin` is a stock, system-shipped PATH entry: `/etc/paths` contains `/System/Cryptexes/App/usr/bin`, and `/etc/paths` is root:wheel 644 (system-managed).
- `/System/Cryptexes/App` is a symlink: `/usr/bin/readlink /System/Cryptexes/App` → `../../System/Volumes/Preboot/Cryptexes/App`. The check follows it (`auckland-vpn:1952-1961`).
- That target's parent is mode 777: `/usr/bin/stat -f '%Lp %Su:%Sg' /System/Volumes/Preboot/Cryptexes` → `777 root:wheel`.
- **No unprivileged user can actually write there.** `test -w /System/Volumes/Preboot/Cryptexes` → *not writable* for the invoking admin user, with `csrutil status` → *enabled*. The check keys on mode bits only (`auckland-vpn:1936,1938-1944`), so it reports writability that SIP denies in practice.
- Consequence on a clean machine — simulating the stock PATH reproduces exactly one PATH-hygiene line, and it is the bogus one:
  `PATH="/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin" auckland-vpn doctor` →
  `WARN  PATH entry /System/Cryptexes/App/usr/bin has a world-writable component: /System/Cryptexes/../../System/Volumes/Preboot/Cryptexes (mode 777)`
  with no `OK` line (checked by `auckland-vpn:1966-1971`).

Why this is worse than ordinary noise:

- `doctor`'s contract is "one `OK`/`FIX` per check — a `WARN` here reads as a security problem" (`auckland-vpn:1836-1840`). A `WARN` that appears on every Mac and that the user cannot clear trains users to ignore the advisory — the opposite of the visibility the ticket wanted (`eval-62-doctor-path.md`, "A warning-only, bounded check is useful").
- It is un-actionable: removing the entry means editing the system-managed `/etc/paths`, and it cannot be chmod'd. There is no fix to print, unlike every `FIX` line.
- It is avoidable: the exclusion is one scoped condition, not a redesign.

**Recommended fix (choose the allow-list, not "accept the noise"):** suppress reporting when the writable component is the known SIP-protected stock Cryptexes path — i.e. a root:wheel-owned component whose real path sits under `/System/Volumes/Preboot/Cryptexes` (and ideally, root:wheel-owned components on a SIP-protected `/System` mount generally). A narrow, commented exclusion is better than switching the whole check to `test -w`/real-access semantics because that would diverge from `path_is_trusted`'s deliberate mode-bit rule (`auckland-vpn:555-559`) that the ticket asked this check to mirror. Add a regression test that pins the stock default PATH and asserts no WARN for it (the existing test cannot catch this — see F2).

---

## Notes (minor / informational — not the verdict driver)

**N1 — Test is hermetic on PATH but not on the sandbox ancestry.** The test pins `PATH` (`tests/run-tests.sh:823,829,833`) but `new_sandbox` places the box under `tests/.tmp.$$` inside the checkout (`tests/run-tests.sh:40-45`), so the "clean" assertion `assert_contains "$out" 'OK   PATH hygiene'` (`tests/run-tests.sh:830`) also depends on every ancestor of the checkout being non-writable. On this machine it passes (suite 25/25); a checkout under a world-writable parent would false-fail. This is the same class of fragility #35 targeted. Because the test pins the PATH, it deliberately never exercises the *stock* default PATH — which is precisely why F1 slipped through. Low severity, but pair the F1 fix with a stock-PATH case.

**N2 — Duplicate findings for a shared writable ancestor.** Each PATH entry walks its own chain (`auckland-vpn:1932-1964`), so N entries sharing one writable ancestor emit N identical WARNs and add N to `warn_total` (e.g. if `/opt` were 777, both `/opt/homebrew/bin` and `/opt/homebrew/sbin` would each re-report `/opt/homebrew` and `/opt`). The 5-line cap (`auckland-vpn:1926,1947`) bounds the output, but the count and early lines are dominated by duplicates. Deduplicating by component path would tighten it.

**N3 — Reported component paths are un-normalised.** The symlink follow builds `dirname(link)/target` (`auckland-vpn:1956-1959`) without collapsing `..`, so the message prints `/System/Cryptexes/../../System/Volumes/Preboot/Cryptexes` rather than the real path. Cosmetic, but it makes the diagnostic harder to read; normalising (or printing the resolved directory) would help.

**N4 — Deliberate divergences, verified and accepted.**
- The advisory omits the owner check that `path_is_trusted` performs (`auckland-vpn:553-554`). For an unprivileged PATH advisory this is defensible: a directory *not* writable by others is not a hijack vector for PATH resolution, and adding the owner gate would warn on ordinary per-user tool dirs. Not a bug; worth a comment if reviewers expect "same rules" to include ownership (the block comment at `auckland-vpn:1917-1918` scopes it to the write rules only).
- The check uses unqualified `tr` for the split (`auckland-vpn:1965`), so a trojaned `tr` on an early PATH entry can suppress its own output. It runs as the same unprivileged user, so there is no privilege boundary to escape, and the task scopes unqualified-call hardening to #55 (`auckland-vpn:1919-1920`). Noted for #55, not counted against this check.
- ACLs are invisible to mode bits; `path_is_trusted` has the same blind spot. Accepted limitation.

---

## Constraint verification (all honoured)

| Constraint | Evidence |
| --- | --- |
| Warn-only; never increments `fixes`, never changes exit code | No `fixes` reference anywhere in `auckland-vpn:1914-1971`; the block only mutates locals (`auckland-vpn:1921`); exit logic still solely on `fixes` (`auckland-vpn:1995-1999`) |
| Group-write tolerated only for admin gid 80 | `auckland-vpn:1941-1942`; confirmed live: `/opt/homebrew/bin` mode 775 gid 80 → no WARN, `/Users/server/.local` 777 gid 20 → WARN |
| Absolute `/usr/bin/stat` | `auckland-vpn:1936,1941` (plus `/usr/bin/readlink` 1955, `/usr/bin/dirname` 1958,1963) |
| Symlink-following ancestor walk, 16-hop cap | `auckland-vpn:1952-1961`; cap at `auckland-vpn:1954` |
| Output capped at first 5 findings + summary count | `auckland-vpn:1926,1947` (cap), `auckland-vpn:1968-1969` (count) |
| Hardening unqualified PATH calls is #55 | Comment `auckland-vpn:1919-1920`; no hardening attempted here |
| Mode-branch correctness | Exercised directly: `777/1777/702/707/766` → world; `770/775/664/2770/660` → group; `755/700/4755` → none; the gid-80 filter then suppresses `775` admin dirs |
| README accuracy | `README.md:98-100` states doctor adds advisory WARNs never counted as failures — matches behaviour |

The new test itself is sound and does what it claims: world-writable ancestor → WARN and no `OK` line (`tests/run-tests.sh:823-827`), repaired → `OK` (`:829-830`), empty entry → WARN (`:833-834`); registered at `tests/run-tests.sh:953`.

---

VERDICT: FIX-FIRST

---

## CONFIRMATION — re-review of fix commit `063278a` (HEAD), 2026-09-16

Read-only round: only this report file was touched (no source edits, no git state change, no `gh` writes). All claims re-verified at the exact lines/commands.

**F1 (Cryptexes false positive) — resolved.** `path_hygiene_sip_exempt` exists wrapper-side at `auckland-vpn:312-318`, immediately after `last_log_error` (`:297-303`), with the annotated one-entry comment (`:305-311`). It skips only when the *canonical* path matches `/System/Volumes/Preboot/Cryptexes` or is under it AND owner:group is `0:0` (`:313-317`). Called at `auckland-vpn:1963-1967`; the skip is surfaced, not silent: `excluded` feeds the INFO line at `:1995-1997`. Direct predicate check (extracted verbatim from `:312-318`) returns: exact `0:0` → SKIP, under-tree `0:0` → SKIP, `/tmp/evil/System/Volumes/Preboot/Cryptexes` `0:0` → REPORT, Cryptexes `501:20` → REPORT, `Cryptexes-evil` `0:0` → REPORT (prefix-sibling, correctly not matched), `/System/Volumes/Preboot` `0:0` → REPORT. Live stock PATH (`/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin`) now prints only the INFO skip + `OK   PATH hygiene` — no WARN. Live user PATH still WARNs on the real `/Users/server/.local` (777) and INFO-skips the cryptex. `csrutil status` = enabled; `/System/Volumes/Preboot/Cryptexes` = `777 root:wheel` (as the review recorded).

**N3 (un-normalised paths) — resolved for the world-writable branch.** `rn="$(cd -- "$p" && /bin/pwd -P)" || rn="$p"` at `auckland-vpn:1962`; the WARN at `:1966` prints `$rn`, so the `..`-littered cryptex spelling is gone. Integration regression `tests/run-tests.sh:846-853` builds a `../`-spelled symlink to a 777 ancestor and asserts the report names the real target. Residual (cosmetic, not a return of N3): the group-writable branch at `:1971` still prints the un-normalised `$p`; a symlinked PATH entry with a group-writable non-admin ancestor would still show `..`. Not verdict-driving.

**Regression asserts + suite.** Direct helper cases at `tests/run-tests.sh:836-845` (exact, under-tree, user-owned, non-root-owned, lookalike) and the symlink integration case at `:846-853`; registered at `:974`. `bash tests/run-tests.sh` → `25 passed, 0 failed`; focused `bash tests/run-tests.sh doctor_warns` → `1 passed`; `shellcheck auckland-vpn` → rc 0. The pre-fix code printed `$p` in the WARN, so the `:853` assertion genuinely pins the N3 change (would fail on `9f5aefc`).

**N1 / N2 wontfix-minor — I agree.** N1 (the `OK   PATH hygiene` assertion depends on the checkout's ancestry) is a pre-existing property of this test and explicitly the same class #35 tracks; the fix does not worsen it, and the alternative — a stock-PATH integration case — cannot be made hermetic in CI (no `/System` writes). N2 (duplicate WARNs for a shared ancestor) is bounded by the 5-line cap at `:1976` and the count in `:2000-2001`; for an advisory that never affects `fixes`/exit status, dedup is polish at most. Neither blocks closure; both would be reasonable follow-ups if this advisory ever grows real pruning.

**Constraint re-check.** Still warn-only: no `fixes` mutation and no exit-code influence in `:1929-2003`; the new `pown`/`rn` are locals (`:1939`); the exclusion cannot be weaponised (SIP denies writes inside the exempt tree, and ownership must be `0:0`). README `:98-100` ("advisory WARNs … never counted as failures") still matches. No new security-relevant surface introduced.

One housekeeping note (not a finding): this report file and `wave-1000-attempt2.md` are untracked in the working tree (`git status` → `??`); per the repo's report-artifact rule they should be committed with the wave.

VERDICT: SATISFIED
