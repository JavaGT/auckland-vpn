# Evaluation: consolidate wave-report trees (#58)

## Verdict

WORTH-DOING. Option (a)—move the two 2026-09-10 reports into `artifacts/reports/2026-09-10/` and update references—is the better default because the split has no stated rule and has already caused a report to land in the wrong directory. The move is small, and a pointer/redirect note can preserve discoverability, but old hard-coded GitHub URLs will still need updating because GitHub does not transparently redirect every old repository path.

## Evidence

- Inventory: `docs/reports/` contains exactly two files, `2026-09-10-pain-journal.md` and `2026-09-10-quick-scan.md` (157 and 65 lines); their headings date both to 2026-09-10 (`docs/reports/2026-09-10-pain-journal.md:1`, `docs/reports/2026-09-10-quick-scan.md:1`).
- Inventory: `artifacts/reports/` contains 15 files: 2026-09-11 (quick-scan, config-review, pain-journal), 2026-09-12 (quick-scan, wave-1000), 2026-09-13 (quick-scan, wave-1000), 2026-09-14 (quick-scan, config-review), 2026-09-15 (quick-scan, config-review, wave-1000), and 2026-09-16 (quick-scan, wave-1000, tests-24of24.log). The report headings identify the playbooks as quick-scan, config-review, wave-1000, and pain-journal (for example, `artifacts/reports/2026-09-11/quick-scan.md:1-4`, `artifacts/reports/2026-09-16/wave-1000.md:1-4`).
- The repository guidance explicitly describes two locations—`docs/reports/` for the 09-10 wave and `artifacts/` for reports plus receipts—rather than one durable report convention (`AGENTS.md:38-43`). The issue body likewise says the split is by date of introduction, not a stated rule (issue #58, read 2026-09-16).
- The split creates a real completeness hazard: the 09-13 wave says blind-spot carry-forward depends on reading all prior reports and calls the trees disjoint (`artifacts/reports/2026-09-13/wave-1000.md:20-30`).
- The ambiguity has caused an operational error: the 09-14 config-review child wrote at the `artifacts/reports/` root instead of the dated convention, then had to be moved (`artifacts/reports/2026-09-14/quick-scan.md:28-33`; corresponding receipt `artifacts/automation-receipts/2026-09-14/unsupplied-20260914T0930-attempt-1-auckland-vpn-0930.md:22`).
- Reference scan: `docs/reports` occurs 12 times across 6 files, chiefly `AGENTS.md`, the two legacy reports, three later reports, and three automation receipts; `artifacts/reports` occurs 28 times across 16 files, chiefly later reports and automation receipts. No matches were found under `scripts/` or `.github/`; README has no match. Receipts record report paths as evidence, so those references must be updated (`artifacts/automation-receipts/2026-09-11/auckland-vpn-1000.md:23-25`; `artifacts/automation-receipts/2026-09-13/unsupplied-20260913T1000-attempt-1-auckland-vpn-1000.md:22-24`).
- History is straightforward: the two legacy files were each added on 2026-09-10 (`git log --follow` shows commits `e60cbfb` and `0f9550c`), while the next wave was added under `artifacts/reports/2026-09-11/` (`3e55502`). A `git mv` should retain file history, but path-based links in reports, receipts, and external bookmarks can break.
- Option (b) would minimize churn but preserves two search roots and the demonstrated wrong-directory failure. Option (a) has limited migration churn (two files plus textual references), improves findability and future automation conventions, and should include a clear `AGENTS.md` pointer or compatibility stub documenting the old paths and new locations.

## Proposed change sketch

**Effort: S. Risk: low-to-moderate.** Create `artifacts/reports/2026-09-10/`, `git mv` both legacy files there, update all 12 `docs/reports` references (and any affected report/receipt links), and change `AGENTS.md` to name one canonical tree. Leave a small `docs/reports/README.md` pointer if desired; explicitly note that old GitHub path URLs are not guaranteed redirects. Run the repository's read-only/reference checks and inspect the diff, but do not alter historical receipt contents unless their path references are intended to remain archival.

## What I did not check

- I did not perform the move, edit source files, commit, stash, reset, checkout, or modify issue #58.
- I did not test GitHub's behavior for old raw/blob URLs or verify external links outside this repository.
- I did not inspect scheduler configuration outside the repository; only committed scripts/workflows and in-repo automation receipts were reference-scanned.
