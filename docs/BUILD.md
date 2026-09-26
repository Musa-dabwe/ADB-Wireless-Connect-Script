# ADB Wireless Connect Script Build Pamphlet

## Overview
- Purpose: Automate wireless Android ADB connections and launch scrcpy screen mirroring.
- Current Version: Unreleased
- Status: Stable Scripts

## Development Timeline

### 2026-09-26 — Hardening and solidification pass
Five tasks over nine commits (`f51e986`..`85e4880`, i.e. `037a402` onward), each ending with `bash -n` clean and the suite green. The pass closed the two open items about scrcpy's startup behavior, gave `scrcpy.sh` a real session lifecycle, and put `start.sh` / `stop.sh` under test for the first time.
- **Standards sweep** (`037a402`): every user-facing install hint uses `pkexec`, never `sudo` — including the three hints `stop.sh` was missing entirely. `print_banner()` no longer calls `clear`, so the terminal scrollback survives every invocation. Option columns aligned.
- **`scrcpy.sh` input handling** (`6ef2440`, `73db823`): a caller-supplied serial is matched with `grep -Fxq --` instead of being interpolated into a regex, where `.` in an IP matched any character. A repeated `-a`/`--args` is rejected instead of silently discarded. `scrcpy --version` is probed and the version field appears on the success line. `set -u` enabled.
- **Session lifecycle** (`5fddc10`, `41a0324`): `-t/--timeout S` (default 2) replaces the hardcoded 1.25s grace period; scrcpy's PID is recorded in `scrcpy.pid` beside the logs; `-f/--force` replaces a running session; `-w/--wait` runs in the foreground and exits with scrcpy's own status — that flag is how the roadmap's "propagate the exit code" item is delivered. The log directory is bounded to the newest 10 logs plus the current one, on the success and failure paths alike. A PID file is trusted only when `/proc/<pid>/cmdline` positively identifies a live scrcpy.
- **`start.sh` / `stop.sh` correctness** (`e22b883`, `4471bf5`): the port is validated at both of its input paths, the device picker is bounds-checked, a double connect failure prints an actionable message instead of dying silently, the post-connect verification matches the target literally, `stop.sh` labels each target with its real adb state, attempts every target after a failure, calls `adb devices` exactly once, and validates adb in one place for every flag including `-k`.
- **Regression suite** (`1864a10`, `85e4880`): `tests/test_start_stop.sh` added — 33 case groups, the first coverage either script has ever had.
Session: docs/sessions/session-2026-09-26-0130-hardening-and-solidification.md

### 2026-09-26 — scrcpy USB support and clearer device diagnostics
`scrcpy.sh` filtered the device list to wireless `host:port` serials, so a USB-connected phone was reported as absent. Detection is now transport-aware (USB, wireless, emulator), and `unauthorized` / `offline` devices plus a missing `adb` binary each report their own fix instead of a generic "connect a device" message.
Session: docs/sessions/session-2026-09-26-1042-scrcpy-usb-support.md

### 2026-09-25 — Reliable scrcpy startup reporting
Diagnosed the libbluray ABI mismatch and fixed the launcher to surface startup failures, retain logs, and preserve background operation.
Session: docs/sessions/session-2026-09-25-0821-fix-scrcpy-launcher.md

## Architecture Overview
The project consists of three standalone Bash entry points: `start.sh` establishes wireless ADB connectivity, `stop.sh` disconnects devices or stops the ADB server, and `scrcpy.sh` selects an authorized connected device — USB, wireless, or emulator — and launches scrcpy. They are deliberately independent and independently copyable: no shared library, no `lib/`, no cross-file sourcing, so some duplication between them is accepted on purpose.

`scrcpy.sh` also owns a small session lifecycle. It backgrounds scrcpy by default, waits a configurable grace period to confirm the process survived startup, records the PID in `scrcpy.pid` and the output in a per-launch `scrcpy.*.log` under `${XDG_STATE_HOME:-$HOME/.local/state}/adb-wireless-connect`, and prunes that directory to the newest 10 logs plus the current one. `--wait` runs in the foreground and returns scrcpy's own exit status; `--force` replaces an existing session. A recorded PID is only acted on when `/proc` identifies it as a live scrcpy, so a stranded or recycled PID can neither block a launch nor cause an unrelated process to be signalled.

Shell options differ per script by decision, not by oversight, and the reason differs between the two scripts that stay on `set -e`.

`scrcpy.sh` runs `set -eu`; all three of its prompts read with `|| choice=1` / `|| res_choice="4"` / `|| fps_choice="3"`, so no prompt can leave a variable unset. Its one non-prompt read — the PID file at `scrcpy.sh:367`, which uses `|| true` rather than an assigned fallback — is safe because the non-empty test at `scrcpy.sh:364` gates it first, so `recorded` is always assigned by the time it is expanded.

`start.sh` stays on `set -e` alone for a concrete reason: its Android 11+ pairing prompts read with `read … || true`, which leaves `pair_addr` and `pair_code` *unset* when there is no tty, and the very next line expands them bare. A blanket `set -u` therefore aborts the no-tty path with `pair_addr: unbound variable` (`start.sh:138`) instead of applying the documented "Pairing details missing" default. Verified by running a `set -eu` copy: that is the exact failure.

`stop.sh` has no such read. Both of its prompts use `|| choice="2"` and `|| choice="3"`, which *assign*, so `-u` would not break its no-tty path — a `set -eu` copy reaches the documented default on both interactive branches and exits 0. It is kept on `set -e` to stay aligned with `start.sh`, not because it needs to be.

The warning that matters: do not "consolidate" all three scripts onto `-eu`. It would look safe, because `stop.sh` and `scrcpy.sh` would both survive it, and it would break `start.sh`'s no-tty path.

## Bugs Discovered & Fixed
### Critical
- scrcpy could not start because the installed scrcpy binary required `libbluray.so.4` while the system provided `.so.3`. Resolved by updating the ABI-coupled `libbluray` and `mpv` packages.
- `scrcpy.sh` rejected USB-connected devices as "no wireless ADB devices found". The device list was filtered by a wireless-only `host:port` regex; detection is now transport-aware.
- A specified serial that was not connected could still match a lookalike device: the serial was interpolated unescaped into a `grep` regex, so the dots in an IP matched any character. `1.2.3.4:5555` was satisfied by `1x2y3z4:5555`. Now matched with `grep -Fxq --`. The same unanchored, unescaped pattern in `start.sh`'s post-connect verification could report a successful wireless connection for a phone that was never reached; it is now `grep -Fq --`.
- A second scrcpy could be launched against the same setup with no warning, and the unbounded log directory grew without limit — every launch created a new log and nothing ever removed one. Sessions are now tracked by PID file and logs are pruned to a bounded set.
- `stop.sh` labelled every wireless serial as an "Active wireless ADB connection" while its filter matched any state, so an `offline` or `unauthorized` target was presented as active. Each entry now carries the state adb actually reports, and a target that is absent from the dump is labelled `unknown` rather than active.

### Medium
- `scrcpy.sh` discarded scrcpy output and reported success even when the process exited immediately. The launcher now verifies startup, surfaces errors, propagates failure status, and records output in a unique per-launch log under the user state directory.
- Devices in `unauthorized` or `offline` state were silently dropped and reported as absent. They are now named with state-specific remediation.
- A missing `adb` binary was misreported as "no connected devices"; an explicit presence check now reports it as such.
- `start.sh` died with no message when a connect attempt and its one retry both failed — `set -e` terminated it right after the "Retrying" line. It now names the target it tried, lists the usual causes, and exits 1.
- `stop.sh` ran `adb disconnect` unguarded. adb returns non-zero for a target it has already dropped, so a stale target killed the script with a bare rc=1 and no message, abandoning every target after it. All disconnects now go through one helper that attempts each target, collects the failures, reports how many of how many failed, exits non-zero if any failed, and suppresses the success line on partial failure.
- `stop.sh` invoked `adb devices` up to three times, so the listing and the state labels could contradict each other. It is now called once and cached; the wireless list, the per-entry labels, and the no-wireless dump all derive from that snapshot.
- `-k` in `stop.sh` ran `check_adb` from inside the argument-parsing loop, validating adb at a different point from every other path. All flags are now parsed into flags and `main()` performs banner, adb check, and kill in one order.
- `start.sh` assigned the Android 11+ pairing prompt's connect port straight to `PORT`, the one gap left in "validate the port before use". Both port inputs now share a single `_valid_port` helper.
- The `--port` range check was 64-bit wrapping arithmetic, so a value that wrapped into range passed validation. Length is tested before the comparison.
- `stop.sh` took only the second whitespace field of an adb status line, so a multi-word status such as `no permissions (user in plugdev group); see [...]` rendered as the nonsense label `(no)`. The whole status line is now used.

### Low
- Out-of-range input in the multi-device picker produced an empty serial instead of falling back to the first device. In `start.sh` the unvalidated index became `-1`, and bash resolves a negative subscript to the *last* device, so garbage silently targeted the wrong phone. Both scripts now normalize the answer, require `^[0-9]+$`, and bounds-check the index.
- A zero-padded picker answer such as `08` aborted both scripts with bash's `value too great for base`, because arithmetic read the leading zero as octal. User-supplied numbers are now normalized in one place per script.
- `print_banner()` called `clear` in all three scripts, destroying the user's terminal scrollback on every invocation. It now prints a blank line instead.
- Every user-facing install hint used `sudo`; `stop.sh` printed no install hints at all. All of them use `pkexec`.
- A repeated `-a`/`--args` in `scrcpy.sh` silently discarded the first batch; it is now rejected with a message naming the option.
- An unwritable state directory left `mktemp` failing with an empty log path, and the launch then blamed scrcpy for a failure that never happened. It is now reported as itself, with the `ls -ld` check the user needs.
- `read -r recorded <"$pid_file" || recorded=""` discarded a valid PID when the file had no trailing newline, because `read` returns non-zero while still assigning.

## Testing Methodology
Two pure-Bash regression suites, both mocking `adb` (and `scrcpy`, `ping`, `sleep`) on `PATH` and driving behavior through `MOCK_*` environment variables. No case contacts a real device, and no case leaves a process running. Each suite prints one `PASS:` line per case group and exits non-zero on the first failed assertion.
- `tests/test_scrcpy_launcher.sh` — 4 case groups covering the `scrcpy.sh` surface: immediate and delayed startup failure with status propagation, background success, concurrent log isolation, device detection across USB / wireless / emulator / unauthorized / offline / pending / empty / missing-adb, literal serial matching, repeated `-a` rejection, trailing `--serial` and `--timeout` under `set -u`, both scrcpy version-probe paths, `--timeout` validation and that the grace period is genuinely honored, the live-PID refusal, `--force` against both a cooperative and a SIGTERM-proof session, stale and unidentifiable PID files, `--wait` propagating 42 and 43, log pruning on the success and failure paths, an unwritable state directory, and a zero-padded `08` picker answer.
- `tests/test_start_stop.sh` — 5 case groups, added in this pass, giving `start.sh` and `stop.sh` their first coverage: `--port` validated at both input paths, unknown-flag rejection, the Android 11+ pairing flow end to end, the device picker on garbage / out-of-range / zero-padded input, the USB happy path, IP selection, the explicit double-connect-failure message, `stop.sh` state labels, one-call `adb devices`, every-target-attempted disconnects, and partial failure not reported as success. The mock `adb` records the exact command line of every invocation, which is what pins "attempted exactly twice" and "called exactly once".
- Interaction: prompts read `/dev/tty`, so cases run in their own session via `setsid` and the documented defaults apply deterministically. The cases that must answer a specific prompt use util-linux `script` for a pty and print a visible `SKIP:` line when it is absent, so an answer-driven case can never pass unnoticed as the default-answer path.
- Mutation checking: each task's cases were verified to go red under the defect they target — 17 of 17 mutations caught in the final `start.sh`/`stop.sh` review round, 24 of 24 in the `scrcpy.sh` session-lifecycle round.
- Integration testing: direct and scripted scrcpy launches against both USB and wireless ADB devices. *(From the earlier launcher and USB-support sessions, not from the hardening pass — that pass was verified entirely against mocks.)*
- Manual testing: OPPO PCLM50 on Android 12, Wayland session, Mesa OpenGL renderer. *(Same caveat: pre-hardening pass.)*

## AI Models & Their Contributions
### Architecture & Complex Logic
- **Space Bunny Free**: Diagnosed the package ABI mismatch and designed the startup-verification behavior; then designed the session-lifecycle model (PID file as the single source of truth for a live session, identity through `/proc/<pid>/cmdline` rather than liveness through `kill -0`, bounded logs retained on the failure path as well as the success path).

### Code Generation & Refactoring
- **Space Bunny Free**: Implemented the launcher fix and the original regression suite; added transport-aware device detection and per-state diagnostics; implemented the `scrcpy.sh` hardening, session lifecycle, and the `start.sh`/`stop.sh` correctness fixes; and wrote `tests/test_start_stop.sh`.

### Specific Implementations
- None.

### How this pass was executed
Every task was implemented by a subagent of the same model that drove the pass, each working from a written task brief and returning a report that a second, independent reviewer held against the brief and the plan's global constraints. Two task subagents were lost mid-task and had to be re-dispatched; Task 3's report records inheriting a killed implementer's uncommitted work, re-verifying it against the brief, and adding the test coverage the lost agent had not produced. Each re-dispatch landed clean and was reviewed again after it landed. No per-model differences are claimed, because there was only one model involved.

## Build Outputs
Location: `~/storage/shared/Docs/Build/`

## Development Resources
- Version Control: Git
- Runtime: Bash, Android Platform Tools, scrcpy
- Testing: two Bash regression harnesses (`tests/test_scrcpy_launcher.sh`, `tests/test_start_stop.sh`), `bash -n`, `git diff --check`

## Future Roadmap
One item from this roadmap is now closed and is deliberately absent rather than ticked: the configurable startup grace period shipped as `scrcpy.sh --timeout` (default 2s). The other open item about scrcpy — propagating its exit code, listed under "Next Session Priorities" in `docs/sessions/session-2026-09-26-1042-scrcpy-usb-support.md` rather than in this file — shipped as `scrcpy.sh --wait`, which blocks in the foreground and exits with scrcpy's own status. Both are described in the 2026-09-26 hardening timeline entry above.

Seven adb invocations, in five places, are still unguarded, so a failure at any of them exits under `set -e` carrying adb's own stderr but no script-authored message. Every other adb call in the three scripts is guarded — by `if !`, by `|| true`, or by sitting inside an `if` condition — and those guards are what make their failures actionable. These are the remaining exceptions, and the realistic trigger for all of them is the same: a device that has dropped off, or an adb server that cannot start.

- [ ] Guard `step_tcpip` in `start.sh` — `adb -s "$DEVICE_ID" tcpip "$PORT"` at `start.sh:254`. This is a real, known gap: it was raised independently during the Task 4 review, the Task 4 fix round, and the Task 5 implementation, and deferred each time because the task carrying the test coverage was test-only, so a fix there would have had no case to gate it. It needs a script-authored message plus a `MOCK_ADB_TCPIP` failure knob in the mock `adb`.
- [ ] Guard the two interactive restart branches in `stop.sh` — `adb kill-server` and `adb start-server` at `stop.sh:142-143` (the no-wireless-devices branch) and `stop.sh:184-185` (menu choice 2). Not previously recorded. The `-k` path at `stop.sh:112-113` *is* guarded and reports itself, so the gap is specific to these two interactive branches. They need the same treatment, plus mock coverage for a failing `adb start-server`.
- [ ] Guard the two post-connect `adb devices` dumps in `start.sh` — `start.sh:294` (`step_verify_wireless`) and `start.sh:302` (`step_disconnect_usb_prompt`). Also not previously recorded. The one at `start.sh:302` is the sharper of the two: a failure there kills the script *before* the `if` on the next line can print "Device not showing as connected wirelessly. Check the IP and try again.", so the friendly diagnostic is lost to a bare exit. The `if` on `start.sh:303` is itself safe, being a condition.
- [ ] Add a case selector to both harnesses. Neither suite can run a single case in isolation; the only granularity today is the whole file. Worth pairing with a decision on the deliberate startup scrub — every `MOCK_*` knob is unset at the top of `tests/test_start_stop.sh` so a value can only come from the case that set it, which means an exported `MOCK_ADB_CONNECT=fail` no longer probes a single behavior.
- [ ] Test normal audio forwarding separately from `--no-audio` startup.
- [ ] Install `shellcheck` and add it to CI. Recommended, and deliberately out of scope for the hardening pass.

Environment caveat on the suites: the cases that must answer a `/dev/tty` prompt — the `08` device-picker case in `tests/test_scrcpy_launcher.sh` and the pairing and picker cases in `tests/test_start_stop.sh` — require util-linux `script` for a pty and print a visible `SKIP:` line when it is missing. They are never silently absent.
