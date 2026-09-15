# Evaluation: doctor PATH-hygiene check (#62)

## Verdict

WORTH-DOING. The live machine has a world-writable PATH component and group-writable Homebrew PATH entries, while `doctor` gives no visibility into that trust boundary. A warning-only, bounded check is useful, especially because the wrapper still invokes several utilities through the inherited PATH; it should inspect each PATH entry's ancestor chain rather than only the leaf directory, and should be coordinated with the separate hardening work in #55.

## Evidence

- `auckland-vpn:1836-1840` defines the doctor output contract: one `OK`/`FIX` line per check, actionable fixes, non-zero only for checks needing fixing; it is otherwise read-only apart from the state-dir write test (`auckland-vpn:1892-1899`).
- Existing doctor checks are: username (`auckland-vpn:1842-1847`), resolved executable `openconnect` (`1849-1854`), `vpnc-script` (`1856-1861`), TOTP secret (`1863-1868`), Keychain/password-file credential (`1870-1878`), helper plus exact passwordless sudo grants (`1880-1890`), state-dir writability (`1892-1899`), current log errors (`1901-1911`), and optional monitor process/state (`1913-1933`).
- The closest existing security check is credential-directory ownership and group/world-write rejection in `ensure_config_dir` (`auckland-vpn:240-260`). The privileged executable trust walk also checks every ancestor, rejects other-write and non-admin group-write, and uses absolute tools (`auckland-vpn:542-573`).
- Live PATH inspection on this machine (splitting `$PATH` and running `/usr/bin/stat -f '%Sp %OLp'` on every existing entry) found direct entries `/Users/server/.local/bin` mode `755`, `/opt/homebrew/bin` mode `775`, and `/opt/homebrew/sbin` mode `775`; the other existing entries were `755` and `/usr/local/bin` plus several bootstrap entries were missing. The PATH entry `/Users/server/.local/bin` has a world-writable ancestor: `/Users/server/.local` is `drwxrwxrwx`, numeric mode `777`, owner `server:staff`. This matches the ticket's reported Ruby warning about `/Users/server/.local` mode `040777`.
- PATH hijacking can affect the wrapper: `brew` is unqualified during prefix discovery (`auckland-vpn:57-69`); `pin` uses `command -v openssl` and unqualified `openssl`/text tools (`1821-1831`); doctor invokes unqualified `security`, `cat`, `pgrep`, `head`, and `sed` (`1870-1933`); and several ordinary paths still use unqualified `stat`/`mktemp` (`250`, `252`, `272`, `901`, `1018`, `1348`, `1420`). #55 specifically records the `stat`/`mktemp` drift and the monitor-log rotation failure mode.
- The highest-impact privileged launch is less exposed: the generated helper sets `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and launches its baked absolute paths (`auckland-vpn:459`, `660-661`), while `cmd_start` validates the executable and vpnc-script ancestor chain (`599-602`). This limits—but does not eliminate—the value of a wrapper-side doctor warning.

## Proposed change sketch

**Effort: M. Risk: low to moderate.** Add a doctor-only informational warning section that splits `PATH`, skips empty entries as the current directory (or reports them explicitly), and bounds output to the first few findings plus a count. For each existing entry, walk its parents to `/` and use the script's macOS/Bash style (`stat -f`, `case`, `printf`/`echo`) to report `INFO/WARN PATH entry ... has group/world-writable component ... (mode ...)`; do not increment `fixes`, do not change execution, and do not prompt. Use absolute `/usr/bin/stat` in this new check to avoid the check itself being fooled; distinguish admin-group `775` from arbitrary group-write consistently with `path_is_trusted`. Add a focused test fixture for a writable ancestor and a clean PATH, then separately resolve #55's unqualified calls rather than silently treating this diagnostic as hardening.

## What I did not check

- I did not modify the script, tests, Git state, GitHub issues, or issue comments.
- I did not run the VPN, `doctor`, the full test suite, ShellCheck, or privileged commands.
- I did not inspect filesystem ACLs, symlink chains, mounted filesystem behavior, or PATH values in other users' environments.
