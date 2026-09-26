# Session: 2026-09-26 01:30
**Duration**: 01:30 - 05:30
**Project**: ADB-Wireless-Connect-Script

## Objective
Take the three entry points from "works on my machine" to "behaves predictably
and is regression-tested". A review of `start.sh`, `stop.sh`, and `scrcpy.sh`
after the USB detection fix in `f51e986` had surfaced defects independent of
that bug: a privilege-escalation standard violation in user-facing output, a
silent failure path in `start.sh`, unvalidated menu input in two scripts, an
unbounded log directory, an unconfigurable startup grace period, no way to learn
scrcpy's exit code, and no tests at all for `start.sh` and `stop.sh`.

Five tasks, nine commits, `037a402`..`85e4880`. Task 6 — this documentation
sync — runs last, deliberately, so the docs describe what actually landed.

## Research Phase
The plan was written from a review pass over all three scripts plus the
existing docs. One prior research file was picked up rather than rewritten:
`docs/feature-research/scrcpy-launch-failure.md` had already recommended
replacing `sudo` with `pkexec` in installation guidance; that recommendation had
never been applied and became Task 1. No new feature-research file was needed —
every item traced to a specific function in a specific script.

## Implementation Steps

### Task 1 — Standards sweep (`037a402`)
1. Replaced every user-facing `sudo` install hint with `pkexec`: `start.sh`'s
   three adb hints, all six in `README.md`, and the block `stop.sh` was missing
   entirely. `pkexec` is one character longer than `sudo`, so the trailing
   distribution comments were re-aligned to keep the column.
   (file: start.sh, stop.sh, README.md)
2. Removed `clear 2>/dev/null || true` from `print_banner()` in all three
   scripts. It destroyed the user's terminal scrollback on every invocation; the
   banner now prints one blank line instead, so it still stands apart from prior
   output. (file: start.sh, stop.sh, scrcpy.sh)
3. Aligned the `scrcpy.sh` `--help` option column and the matching README block.
   (file: scrcpy.sh, README.md)

### Task 2 — `scrcpy.sh` input handling (`6ef2440`, `73db823`)
4. `detect_device()` matched a caller-supplied serial with
   `grep -q "^${DEVICE_SERIAL}$"`, interpolating it unescaped into a regex, so
   `.` in an IP matched any character and `1.2.3.4:5555` was satisfied by
   `1x2y3z4:5555`. Now `grep -Fxq --`. (file: scrcpy.sh:221)
5. A repeated `-a`/`--args` is rejected with a message naming the option. The
   first `-a` swallows the rest of the command line, so the duplicate can only
   appear inside that batch — where the old code forwarded a literal `-a` to
   scrcpy as an unknown option. The existing `-s`/`--serial` batch scan is
   preserved. (file: scrcpy.sh:71-91)
6. `check_scrcpy()` runs `scrcpy --version` and shows the version on the success
   line. A failing probe warns and continues — a failed probe is not proof that
   scrcpy is unusable, and the existing startup check catches real failures.
   (file: scrcpy.sh:143-172)
7. Enabled `set -u`. Exactly one expansion broke (an unguarded `"$2"` in the
   `-s`/`--serial` arm, now `"${2:-}"`), and the fix produced a friendly message
   where the script previously died with `unbound variable`. (file: scrcpy.sh:2)

### Task 3 — Session lifecycle and log retention (`5fddc10`, `41a0324`)
8. `-t/--timeout S` (default 2) replaces the hardcoded `sleep 1.25`, rejecting
   non-numeric, negative, zero, and bare values. Zero is rejected separately
   because it is well-formed but means "no grace period", which would race a
   healthy slow start. Fractional values are accepted. (file: scrcpy.sh:101-125)
9. The launch records scrcpy's PID in `scrcpy.pid` beside the logs and prints
   the path. A live PID there refuses a second session, naming the PID and the
   exact `kill` command; `-f/--force` stops it and proceeds, escalating from
   `SIGTERM` to `SIGKILL` after about a second. A stale PID file never blocks a
   launch and is overwritten silently. (file: scrcpy.sh:332-403, 457-464)
10. `_prune_logs` keeps the newest 10 `scrcpy.*.log` files and never deletes the
    current launch's log. Pruning runs on the startup-failure path too, not only
    after success: a device that will not start is exactly when a user retries.
    (file: scrcpy.sh:405-421, 510, 519)
11. `-w/--wait` runs scrcpy in the foreground, still redirected to its log, blocks
    until it exits, removes the PID file, and returns scrcpy's own status. The
    default path is unchanged, so existing workflows and the pre-existing suite
    are unaffected. (file: scrcpy.sh:423-449, 478-489)

### Task 4 — `start.sh` and `stop.sh` correctness (`e22b883`, `4471bf5`)
12. The multi-device picker now normalizes the answer, requires `^[0-9]+$`, and
    bounds-checks the index. Unvalidated input produced `idx=-1`, and bash
    resolves a negative subscript to the *last* device, so garbage silently
    connected the wrong phone. The prompt now advertises its default.
    (file: start.sh:98-128)
13. `--port` is validated before use — all digits, 1024–65535 — with the
    offending value named. Length is tested before the arithmetic comparison,
    because bash arithmetic is 64-bit and wraps: `18446744073709557171` compares
    equal to 5555 and would otherwise pass. (file: start.sh:31-37, 53-67)
14. `step_connect()` prints an explicit failure when the retry also fails:
    names `$DEVICE_IP:$PORT`, states that both attempts failed, lists the usual
    causes, and exits 1. (file: start.sh:270-289)
15. The Android 11+ pairing prompt is the second way of setting `PORT`, so it
    now shares the same `_valid_port` helper. An empty answer keeps the already
    validated default. (file: start.sh:149-160)
16. `step_disconnect_usb_prompt()` greps with `grep -Fq --`, so the dots in the
    IP are no longer regex wildcards that could match a lookalike serial.
    (file: start.sh:303)
17. `stop.sh` labels each target with the state read from `adb devices` instead
    of calling every one "Active". The filter is deliberately unchanged —
    `adb disconnect` on a stale target is a legitimate cleanup. (file: stop.sh:62-67, 153-157)
18. All disconnects go through one helper that attempts every target, collects
    the failures, reports how many of how many failed, exits non-zero if any
    failed, and suppresses the success line on partial failure. (file: stop.sh:75-104)
19. `adb devices` is called once and cached; the wireless list, the state labels,
    and the no-wireless dump all derive from that snapshot, so the listing can
    never contradict itself. (file: stop.sh:123-132)
20. `-k` is parsed into a flag so `main()` does banner → `check_adb` → kill.
    adb is now validated in exactly one place, and a failing `adb kill-server`
    reports itself. (file: stop.sh:38-45, 106-118)

### Task 5 — Regression suite for `start.sh` and `stop.sh` (`1864a10`, `85e4880`)
21. `tests/test_start_stop.sh` added, following the existing harness pattern:
    mock `adb` / `ping` / `sleep` on `PATH` driven by `MOCK_*` variables, one
    runner call per case, a `fail()` helper, an `EXIT` trap, and a `PASS:` line
    per case group. 33 case groups.
22. The mock `adb` records the exact command line of every invocation, which is
    what lets a case assert *what* adb was asked to do and *how often* — not
    just the exit status. That is how "connect attempted exactly twice" and
    "`adb devices` called exactly once" are pinned.
23. Two negative assertions in the first version could not fail: both grepped the
    output for a lowercase `disconnect <serial>`, but `stop.sh` prints
    `[*] Disconnecting <serial>…` with a capital D. They now assert on the call
    log. (file: tests/test_start_stop.sh:724-730, 752-761)
24. Every `MOCK_*` knob is unset at the top of the suite, so a value can only
    come from the case that set it. Inside a bash function an exported
    `MOCK_ADB_CONNECT=fail` is indistinguishable from a per-case prefix
    assignment. (file: tests/test_start_stop.sh:19-31)
25. The wall-clock bound on the happy path was replaced by recording the
    durations the `sleep` stub is asked for. The happy path only ever spends the
    2s settle, which is inside the noise of a loaded machine, so "the suite was
    fast" was never evidence that anything was stubbed.
    (file: tests/test_start_stop.sh:138-153, 510-511, 607-608)

### Task 6 — Documentation sync
26. `README.md`: the three new `scrcpy.sh` flags, a session-management section
    (PID file path, log retention, `--wait`, `--force`), the new `start.sh` port
    validation and connect-failure behaviour, the `stop.sh` state labels and
    partial-failure contract, and a `Tests` section. All three options blocks
    are now byte-identical to the corresponding `--help` option lines, checked
    mechanically.
27. `docs/BUILD.md`: timeline entry for the pass, the fixed bugs, Testing
    Methodology for both suites, and the roadmap.
28. This session document.

## Bugs Discovered & Fixed
- **Bug HS-001**: a specified serial that was not connected could still match a
  lookalike device.
  - Root cause: `scrcpy.sh` `detect_device()` interpolated the serial into a
    `grep` regex, so `.` matched any character.
  - Fix applied: `grep -Fxq --`.
  - File: scrcpy.sh
  - Status: FIXED
- **Bug HS-002**: the same unanchored, unescaped match in `start.sh` could
  report a successful wireless connection for a phone that was never reached.
  - Root cause: `grep` with `"$DEVICE_IP:$PORT"` unescaped and unanchored.
  - Fix applied: `grep -Fq --`.
  - File: start.sh
  - Status: FIXED
- **Bug HS-003**: `start.sh` died with no message when a connect attempt and its
  one retry both failed.
  - Root cause: a bare trailing `_try_connect` returned non-zero and `set -e`
    terminated the script right after the "Retrying" line.
  - Fix applied: an explicit failure naming the target, its causes, and a next
    step, then exit 1.
  - File: start.sh
  - Status: FIXED
- **Bug HS-004**: garbage in `start.sh`'s device picker silently targeted the
  wrong phone.
  - Root cause: unvalidated input produced `idx=-1`, and bash resolves a negative
    subscript to the last device. Non-integer input was worse — it died inside
    arithmetic with a bare bash error and no script message.
  - Fix applied: normalize, require `^[0-9]+$`, bounds-check, default to the
    first device.
  - File: start.sh
  - Status: FIXED
- **Bug HS-005**: a zero-padded picker answer (`08`) aborted both scripts with
  bash's `value too great for base`.
  - Root cause: arithmetic read the leading zero as an octal digit.
  - Fix applied: one `_normalize_number` helper per script, called before any
    arithmetic on a user-supplied number.
  - File: start.sh, scrcpy.sh
  - Status: FIXED
- **Bug HS-006**: `stop.sh` labelled every wireless serial as an "Active wireless
  ADB connection" regardless of state.
  - Root cause: a hardcoded label over a filter that matches any state.
  - Fix applied: the state is read from the cached `adb devices` dump; a serial
    absent from the dump is labelled `unknown` rather than active.
  - File: stop.sh
  - Status: FIXED
- **Bug HS-007**: one failing `adb disconnect` abandoned every target after it.
  - Root cause: `adb disconnect` was unguarded, and adb returns non-zero for a
    target it has already dropped — so a stale target killed the script with a
    bare rc=1 and no message.
  - Fix applied: one `disconnect_targets` helper that attempts each target,
    collects the failures, and returns non-zero if any failed.
  - File: stop.sh
  - Status: FIXED
- **Bug HS-008**: a partial disconnect was reported as a complete one.
  - Root cause: the success line was printed on the aggregate path regardless.
  - Fix applied: the success line is suppressed unless every target was
    disconnected.
  - File: stop.sh
  - Status: FIXED
- **Bug HS-009**: the wireless target list and its state labels could contradict
  each other.
  - Root cause: up to three separate `adb devices` invocations.
  - Fix applied: one call, cached, with the list, the labels, and the
    no-wireless dump all derived from the snapshot.
  - File: stop.sh
  - Status: FIXED
- **Bug HS-010**: `-k` in `stop.sh` validated adb at a different point from every
  other path.
  - Root cause: `check_adb` ran from inside the argument-parsing loop.
  - Fix applied: `-k` parsed into a flag; `main()` does banner → check → kill.
  - File: stop.sh
  - Status: FIXED
- **Bug HS-011**: an invalid port at the Android 11+ pairing prompt reached
  `adb connect 192.168.1.50:<junk>`.
  - Root cause: the prompt assigned straight to `PORT`, the one gap left in
    "validate the port before use".
  - Fix applied: both port inputs share `_valid_port`.
  - File: start.sh
  - Status: FIXED
- **Bug HS-012**: a port value that wrapped in 64-bit arithmetic passed the range
  check.
  - Root cause: `(( value >= 1024 && value <= 65535 ))` on an untruncated integer.
  - Fix applied: length is tested first.
  - File: start.sh
  - Status: FIXED
- **Bug HS-013**: a multi-word adb status rendered as the label `(no)`.
  - Root cause: the label took only the second whitespace field.
  - Fix applied: the whole remainder of the status line is used.
  - File: stop.sh
  - Status: FIXED
- **Bug HS-014**: a second scrcpy could be launched against the same setup with
  no warning, and the log directory grew without limit.
  - Root cause: no session tracking, and every launch created a new `mktemp`
    log that nothing ever removed.
  - Fix applied: PID file plus bounded log retention.
  - File: scrcpy.sh
  - Status: FIXED
- **Bug HS-015**: a stranded or recycled PID could make the launcher falsely
  refuse, or make `--force` `SIGTERM` then `SIGKILL` an unrelated process.
  - Root cause: the guard used `kill -0`, which proves only that *something*
    owns the number.
  - Fix applied: `_process_is_scrcpy` confirms identity through
    `/proc/<pid>/cmdline`, matching a whole argv entry named `scrcpy`. Anything
    short of a positive match counts as a stale PID file and is overwritten —
    never refused, never signalled.
  - File: scrcpy.sh
  - Status: FIXED
- **Bug HS-016**: an unwritable state directory was misreported as a scrcpy
  startup failure.
  - Root cause: `launch_scrcpy` runs with errexit suspended by its caller, so a
    failing `mktemp` left `log_file` empty and the launch blamed scrcpy for a
    failure that never happened.
  - Fix applied: reported as itself, with the `ls -ld` check the user needs.
  - File: scrcpy.sh
  - Status: FIXED
- **Bug HS-017**: a PID file with no trailing newline had its valid PID
  discarded.
  - Root cause: `read` returns non-zero for such a file even though it assigns,
    so a `|| recorded=""` fallback threw the value away.
  - Fix applied: `|| true`.
  - File: scrcpy.sh
  - Status: FIXED
- **Bug HS-018**: a repeated `-a`/`--args` silently discarded the first batch.
  - Root cause: the second occurrence could only land inside the first batch,
    where it was forwarded to scrcpy as an unknown option.
  - Fix applied: rejected with a message naming the option.
  - File: scrcpy.sh
  - Status: FIXED
- **Bug HS-019**: every user-facing install hint used `sudo`; `stop.sh` printed no
  install hints at all.
  - Root cause: guidance predated the project's `pkexec` standard, and one
    script's `check_adb` had no hint block.
  - Fix applied: all hints use `pkexec`.
  - File: start.sh, stop.sh, scrcpy.sh, README.md
  - Status: FIXED
- **Bug HS-020**: `print_banner()` destroyed the user's terminal scrollback on
  every invocation.
  - Root cause: `clear 2>/dev/null || true` in all three scripts.
  - Fix applied: one blank line instead.
  - File: start.sh, stop.sh, scrcpy.sh
  - Status: FIXED
- **Bug HS-021**: `step_tcpip` in `start.sh` has no error handling.
  - Root cause: `adb -s "$DEVICE_ID" tcpip "$PORT"` is unguarded, so a failure
    exits under `set -e` with only adb's raw stderr and no script-authored
    message.
  - Fix applied: **none — deliberately deferred.** A fix needs a
    `MOCK_ADB_TCPIP` failure knob and a case to gate it, and the task that owned
    the test coverage was test-only. Recorded as a follow-up instead of being
    quietly dropped.
  - File: start.sh
  - Status: PENDING
- **Bug HS-022**: the two interactive restart branches in `stop.sh` have no error
  handling.
  - Root cause: `adb kill-server` and `adb start-server` are unguarded at
    `stop.sh:142-143` and `stop.sh:184-185`, so a failure exits under `set -e`
    with only adb's raw stderr. The `-k` path at `stop.sh:112-113` *is* guarded,
    so the gap is specific to the two interactive branches.
  - Fix applied: **none — out of scope for a documentation task.** Found while
    documenting, not while hardening: it was not identified during Tasks 1–5.
  - File: stop.sh
  - Status: PENDING
- **Bug HS-023**: the two post-connect `adb devices` dumps in `start.sh` have no
  error handling — but they are not the same severity, and the first version of
  this record said they were.
  - Root cause: both calls are unguarded. `start.sh:294`, in
    `step_verify_wireless`, is **fatal**: that function is called as a plain
    statement at `start.sh:324` and `start.sh:334`, so a failing `adb devices`
    exits the script with only adb's own stderr. `start.sh:302`, in
    `step_disconnect_usb_prompt`, is **cosmetic only**: the function has one call
    site, `if ! step_disconnect_usb_prompt` at `start.sh:325`, and bash suspends
    `errexit` across the whole dynamic extent of a function invoked in a negated
    condition. A failure there prints adb's raw stderr and execution continues to
    the `if` on the next line, which still prints "Device not showing as
    connected wirelessly. Check the IP and try again." and returns 1 normally.
    Verified end to end against a mock adb that fails only that call: rc=1 via
    the ordinary `return 1` path, and the friendly diagnostic still appears.
  - Fix applied: **none — out of scope for a documentation task.** Also found
    while documenting, not while hardening.
  - File: start.sh
  - Status: PENDING

Between them, HS-021, HS-022, and HS-023 are the only adb invocations in the
three scripts that get no explicit guard — seven calls in five places, since each
`stop.sh` branch makes two. **Six are fatal; `start.sh:302` is cosmetic**, for
the reason given in HS-023. Every other adb call is guarded by one of four
mechanisms: `if !` around the call (`stop.sh:80`, `stop.sh:112`); `|| true`
(`start.sh:141`, `start.sh:189`, `start.sh:262`, `start.sh:318`, `stop.sh:124`);
sitting inside an `if` condition (`start.sh:303`); or being a non-final element
of a pipeline, so the pipeline's status is the last command's rather than adb's
(`start.sh:100`, `scrcpy.sh:190`, `scrcpy.sh:195`, and `start.sh:189` again as
belt-and-braces).

## Testing Performed
- **Unit Tests**: `bash tests/test_scrcpy_launcher.sh` — PASS, 4 case groups,
  approximately 56 seconds. `bash tests/test_start_stop.sh` — PASS, 5 case
  groups, approximately 4 seconds. Each suite mocks the tools it drives —
  `test_scrcpy_launcher.sh` mocks `adb` and `scrcpy`, `test_start_stop.sh` mocks
  `adb`, `ping`, and `sleep` — by placing them on `PATH`; no case contacts a real
  device and no case leaves a process running.
- **Regression Testing**: `bash -n` clean on all three scripts and both test
  files; the pre-existing `scrcpy.sh` assertions from `f51e986` pass unchanged at
  every one of the nine commits, including the four background-launch cases that
  the default (non-`--wait`) path must not alter.
- **Mutation testing**: each task's cases were checked against the defect they
  target. The Task 5 review round reports 17 mutations attempted and 17 caught;
  the Task 3 fix round reports 24 of 24. Every new case in this pass was
  required to go red under the corresponding mutation before it counted.
- **Negative controls**: two assertions in the first `tests/test_start_stop.sh`
  were found to be unfailable — they grepped the output for a lowercase
  `disconnect <serial>` while `stop.sh` prints `Disconnecting` with a capital D.
  Both were rewritten against the mock's call log and confirmed to fail under
  the matching mutation. The `sleep` stub now records the durations it is asked
  for, so "the stub ran" is asserted directly instead of inferred from
  wall-clock time.
- **Manual Testing**: none in this pass. Every change was exercised against
  mocks; no live device or real `adb` call was involved. Manual verification
  remains open — see Issues & Blockers.
- **Environment caveat**: the answer-driven cases need a pty and use util-linux
  `script`, which is installed here, so nothing skipped. Where it is absent they
  print a visible `SKIP:` line rather than passing silently as the
  default-answer path.

## AI Models Used & Their Role
- **Space Bunny Free**: planned the pass, dispatched each task to a subagent with
  a written brief, reviewed every task's report against the brief and the plan's
  global constraints, re-dispatched the two tasks whose agent was lost, and
  wrote the documentation sync.
  - Tasks: planning, dispatch, review, rulings, documentation
  - Effectiveness: high — the review rounds each found real defects that the
    implementing agent had shipped (the unfailable assertions, the
    `read`-returns-nonzero PID file, the wrapping port check, the unguarded
    `adb disconnect`, the version field that leaked the upstream URL).
- **Space Bunny Free** (task subagents, one model, five tasks): implemented
  Tasks 1–5 and their fix rounds, wrote both the new cases and the fixes those
  cases found, and mutation-checked their own work.
  - Tasks: implementation and tests for all five tasks
  - Effectiveness: high, with the caveat that two task subagents were lost
    mid-task and their work had to be re-dispatched. Task 3's report records
    inheriting a killed implementer's uncommitted work and re-verifying it line
    by line against the brief; which task the second was is not recorded in the
    surviving artifacts, and is not guessed at here. Because only one model was
    involved, no per-model comparison is claimed.

## Key Decisions Made
- **Adopt `pkexec`, never `sudo`**, in script output and in `README.md` alike.
  The recommendation already existed in
  `docs/feature-research/scrcpy-launch-failure.md` and had simply never been
  applied.
- **`scrcpy.sh` runs `set -eu`; `start.sh` and `stop.sh` deliberately stay on
  `set -e` alone.** Not an oversight, and not an oversight to be cleaned up
  later. The reason is `start.sh`'s, and it is specific: its Android 11+ pairing
  prompts read with `read … || true`, which leaves `pair_addr` and `pair_code`
  *unset* when there is no tty, and the next line expands them bare. A blanket
  `set -u` therefore aborts the no-tty path with `pair_addr: unbound variable`
  (`start.sh:138`) instead of applying the documented "Pairing details missing"
  default. Verified by running a `set -eu` copy against a mock adb with no tty:
  that is the exact failure, where the shipped `set -e` script prints the
  default and exits 1. `scrcpy.sh` can use `-u` because its prompts always assign
  a fallback.
  `stop.sh` is a different case and is kept aligned rather than kept out of
  necessity: it has no `|| true` read at all — both its prompts use
  `|| choice="2"` and `|| choice="3"`, which *assign* — so `-u` would not break
  its no-tty path. A `set -eu` copy reaches the documented default on both
  interactive branches and exits 0. The warning worth keeping is therefore
  narrow and specific: do not consolidate all three scripts onto `-eu`. It would
  look safe, because `scrcpy.sh` and `stop.sh` would both survive it, and it
  would break `start.sh`.
- **Keep the default `scrcpy.sh` path non-blocking.** `--wait` is opt-in so that
  existing workflows and the pre-existing suite are untouched by the lifecycle
  work.
- **Trust a PID file only on positive identity.** The fallback direction is
  deliberate: a PID file that does not positively identify a live scrcpy is
  treated as stale and overwritten, because overwriting a stale file is harmless
  whereas refusing or killing a stranger's process is not.
- **Prune logs on the failure path too.** A device that will not start is
  exactly the case where a user retries, so the directory has to stay bounded
  either way.
- **Keep `stop.sh`'s wireless filter as-is** and change only the label.
  `adb disconnect` on a stale target is a legitimate cleanup; the defect was
  the presentation, not the selection.
- **Validate the port through one shared helper at both input paths.** Two input
  paths with two checks is exactly how they drift, and the length test comes
  before the arithmetic comparison because bash arithmetic is 64-bit and wraps.
- **Defer `step_tcpip` deliberately, and say so.** It was raised independently in
  the Task 4 review, the Task 4 fix round, and the Task 5 implementation, and
  deferred each time because the task carrying the test coverage was test-only.
  It is recorded as a follow-up with the reason, not dropped.
- **Scrub every `MOCK_*` knob at suite startup.** This is a deliberate behaviour
  change: an exported `MOCK_ADB_CONNECT=fail` no longer probes a single
  behavior, because inside a bash function it is indistinguishable from a
  per-case prefix assignment. The scrub loop unsets ten knobs, and the suite is
  green with all ten exported and red with the scrub removed.
- **No case selector.** Both suites can only run whole. Accepted for this pass
  and recorded as a follow-up.
- **Leave `shellcheck` alone.** Worth doing, deliberately out of scope, recorded
  as a recommendation.

## Build Outputs Generated
None. This session changed source and documentation only; no compiled artifact or
external build export was produced.

## Issues & Blockers
- No live-device or integration verification was performed in this pass. All
  evidence is from the mocked suites plus `bash -n`. The new `start.sh` /
  `stop.sh` behaviour in particular — the explicit connect-failure message, the
  state labels, the partial-disconnect path — has been exercised only against
  mocks and should be confirmed against a real phone before it is trusted.
- Two task subagents were lost mid-task. Task 3's report records inheriting a
  killed implementer's uncommitted work, re-verifying it against the brief,
  fixing three defects in it, and writing the test coverage the brief had asked
  for and the lost agent had not produced. Both re-dispatches landed clean, but
  the lost agents' intermediate review comments are not recoverable.
- `docs/plans/2026-09-26-hardening-and-solidification.md` is scratch input from
  the planning run and is intentionally untracked. It is not a deliverable and
  is not referenced as one.
- The two closed roadmap items are still listed as open in
  `docs/sessions/session-2026-09-26-1042-scrcpy-usb-support.md` under "Next
  Session Priorities". That file is a historical record of that session and was
  left as written; the authoritative status is in `docs/BUILD.md`.

## Performance Metrics
- Regression test runtime: `tests/test_start_stop.sh` approximately 4 seconds;
  `tests/test_scrcpy_launcher.sh` approximately 56 seconds.
- Change size across `f51e986`..`85e4880` — the nine commits of Tasks 1–5; this
  documentation task's own changes are not in this figure: 1784 insertions, 72
  deletions across six files — `scrcpy.sh` +273/-20, `start.sh` +78/-12,
  `stop.sh` +90/-23, `tests/test_scrcpy_launcher.sh` +507/-9,
  `tests/test_start_stop.sh` +828 (new), `README.md` +8/-8.
- Current sizes: `scrcpy.sh` 546 lines, `start.sh` 346, `stop.sh` 194,
  `tests/test_scrcpy_launcher.sh` 691, `tests/test_start_stop.sh` 828.
- Startup grace period: 1.25s hardcoded before, configurable with a 2s default
  now.
- Log directory: unbounded before, at most 11 logs per state directory now,
  plus the `scrcpy.pid` file that shares it.
- Code complexity change: moderate increase in `scrcpy.sh` (session lifecycle)
  and in test code; `start.sh` and `stop.sh` grew only where a validation or an
  error path was added.

## Next Session Priorities
- [ ] Guard `step_tcpip` in `start.sh`, with a `MOCK_ADB_TCPIP` failure knob and
  a case to gate it.
- [ ] Guard the two interactive restart branches in `stop.sh`
  (`stop.sh:142-143`, `stop.sh:184-185`) and the two `adb devices` dumps in
  `start.sh` (`start.sh:294`, `start.sh:302`). Both groups were found while
  documenting this pass, not during Tasks 1–5 — see Bugs HS-022 and HS-023.
- [ ] Add a case selector to both harnesses so a single case can be run in
  isolation, and revisit the `MOCK_*` startup scrub alongside it.
- [ ] Manually verify the new `start.sh` / `stop.sh` output against a real
  device.
- [ ] Test normal audio forwarding separately from `--no-audio` startup.
- [ ] Install `shellcheck` and add it to CI.

## Related Sessions
- See also: session-2026-09-26-1042-scrcpy-usb-support.md
- Continuation of: session-2026-09-26-1042-scrcpy-usb-support.md
- See also: session-2026-09-25-0821-fix-scrcpy-launcher.md
- Research input: `docs/feature-research/scrcpy-launch-failure.md` (its `pkexec`
  recommendation became Task 1)
