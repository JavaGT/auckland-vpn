# Quick-scan — 2026-09-20 (hotspot pass)

Scope: commits since 2026-09-06 — 95c4bdc (pid-file probe), 801613a (REALM
warning), 9f5aefc + 063278a (doctor PATH hygiene), 1fc97c1 + 343c212 (username
validation) — plus immediate neighbors in `auckland-vpn` and
`tests/run-tests.sh`. Anti-list: 42 open issues at scan time; nothing below
duplicates one. Suite baseline: `bash tests/run-tests.sh` → 26 passed, 0
failed. All findings re-verified with sed/grep at exact lines and live /tmp
probes.

## Findings (ranked strength x leverage)

### 1. Symlink jump abandons the pre-link ancestor chain — doctor PATH-hygiene under-reports; path_is_trusted shares the walk shape — Strong

`auckland-vpn:1979-1992` (doctor walk) and `auckland-vpn:571-597`
(path_is_trusted, inside the generated-helper heredoc). When a walked
component is a symlink, the loop follows the target
(`p="$t"` / `p="$(dirname "$p")/$t"`) and continues from the TARGET's
ancestors — the symlink's own parent directory is never stat'd. A
world-writable dir that an attacker must control to plant/replace the link is
invisible to both checks.

Evidence (live probes, /tmp):
- Doctor: `PATH=/tmp/qs-scan/box/dirty/link/bin` with `dirty` mode 777 and
  `link → real/bin` (755 chain) → `cmd_doctor` prints
  `OK   PATH hygiene: no group/world-writable component on any PATH entry`.
  Control without the symlink (`/tmp/qs-scan/box/direct/bin`, parent 777)
  correctly WARNs `world-writable component: /private/tmp/qs-scan/box/direct (mode 777)`.
- path_is_trusted (real emitted helper code, awk-extracted and sourced):
  `path_is_trusted("/tmp/qs-scan/box/dirty/link2")` with `link2 → /opt/homebrew/bin`
  and parent `dirty` 777 → **rc=0 (trusted)**, while the same function on
  `…/box/dirty` itself → rc=1.

Reachability: doctor — any PATH entry whose chain contains `dir/link/…`
(non-final symlink with ≥1 directory between link and leaf); latent for
path_is_trusted (baked OC/VPNC_SCRIPT paths have no symlink components on
stock installs, but `command -v openconnect` fallback, `auckland-vpn:69`, can
resolve through such a PATH). Suggested disposition: **ticket as Strong** —
after following a link, also walk the symlink's own parent chain (resume
dirname on the pre-link path), in both walks.

### 2. Startup username validation defeats the documented "bare/unknown shows help, exits 2" contract — Worth exploring

`auckland-vpn:218-223`: invalid `VPN_USER` env dies at source time, before
dispatch; `load_config` (same block) already did this for malformed config
files. README:107-108 promises unconditionally: "Running bare `auckland-vpn`
(or an unknown command) shows help and exits 2". Probe:
`VPN_USER='bad user' bash auckland-vpn help` → rc=1, prints only the
validation error — no usage, and `help`/`doctor` are unreachable until the env
var is fixed. Fail-fast has a rationale (loud corruption detection), so the
likely fix is a README caveat ("unless startup validation fails") rather than
moving validation. Suggested disposition: **Worth exploring** (docs-truth-up
or deferred validation; owner's call).

### 3. doctor reports all-OK for an openconnect lacking --pid-file — Worth exploring

`auckland-vpn:1871-1876` checks only `-x "$OPENCONNECT_BIN"`; the capability
gate lives in `cmd_setup_sudo` (`auckland-vpn:907`) and the generated helper
(`OC_HAS_PID_FILE` bake, `auckland-vpn:427/476`, start-side die
`auckland-vpn:624`). So on an old openconnect, `doctor`/`diagnose` say
`OK openconnect found`, and the user learns of the prerequisite only when
`setup-sudo` or `start` fails — against doctor's stated contract ("check every
prerequisite", README:98). Complements (does not duplicate) #26. Suggested
disposition: **Worth exploring** — one `openconnect_supports_pid_file` FIX
line in cmd_doctor.

### 4. PATH-hygiene WARN ignores the sticky bit — safe shared dirs always WARN — Worth exploring (small)

The walk's mode glob `*[2367]` sees `%Lp` permission bits only; the sticky bit
that makes `/private/tmp` (1777) safe is invisible. Probe 3b printed
`WARN … world-writable component: /private/tmp (mode 777)` for the standard
macOS temp dir. Any user with a PATH entry under /tmp or /var/tmp gets a
permanent scary WARN on an inert ancestor, training them to ignore WARNs.
(#71 covers the group-writable branch, raw `$p`, and empty PATH — not this.)
Suggested disposition: **Worth exploring** — exempt sticky world-writable dirs
the way 063278a exempted the Cryptexes tree.

### 5. no-finding — disproven candidate worth recording

Suspected `%Lp` vs `%u:%g` inconsistency in the world-writable branch
(`auckland-vpn:1957-1968`: does the mode follow the symlink while the owner
does not?). Probe 1 disproves it: on macOS, `stat -f '%Lp'` does NOT follow
symlinks (symlink shows its own 755, target 777 shows 777), so mode and owner
are self-consistent. No finding.

## Clean regions (explicit no-finding results)

- **95c4bdc pid-file probe** (`auckland-vpn:229-237`): capture-then-grep is
  correct under `set -euo pipefail`; comment accurately describes both failure
  modes; stub now exits 1 faithfully and the new bake test
  (`tests/run-tests.sh:298-309`) pins the regression. Neighboring `| grep`
  pipes (`auckland-vpn:295,344-348,364,802,893,978`) are all inside if/&&
  conditions or `|| true` — no residual #83-shaped pipefail hazard. Clean.
- **801613a REALM warning** (`auckland-vpn:2087-2091`): now self-contained,
  factually matches the audit note and README:178-181, no dead repo path.
  Clean.
- **Username validation (343c212 + 1fc97c1)** apart from finding 2:
  `username_is_valid` (`auckland-vpn:91-97`) is the single rule; config
  (trim → quote-strip → balanced-quote die → empty die → validity → conflict
  die), env (`auckland-vpn:219`), and setup prompt (`auckland-vpn:1053-1058`)
  all route through it and match README:44-50 exactly (per-source semantics
  documented correctly). Only one config-save path exists
  (`save_vpn_user_to_config`, `auckland-vpn:1034`; the `VPN_USER=%q` at
  `auckland-vpn:469` is the helper bake, not a second save). Clean.
- **063278a Cryptex exemption** (`path_hygiene_sip_exempt`,
  `auckland-vpn:305-317`): narrow two-condition allow-list, tests cover exact/
  under/lookalike/non-root. Clean apart from finding 4's sticky-bit noise.

## What I did not look at

- monitor state machine, heal/backoff internals (#22, #43, #44, #46 lanes).
- cmd_secret / password prompt paths (#74, #80, #27 own them).
- generate_helper body beyond path_is_trusted, sudoers fragment (#75), helper
  stop paths (#23, #28).
- installer/update lineage (#37), CI (#48, #20), docs/consults content (#77),
  prior report archives.
- Test-harness hygiene beyond the hotspot tests (#78, #79 lanes).
- `/opt/homebrew/bin/auckland-vpn` deployed-copy drift (#33).
