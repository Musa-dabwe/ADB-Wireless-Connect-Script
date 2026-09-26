#!/usr/bin/env bash
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home" "$TEST_DIR/state"

cat >"$TEST_DIR/bin/adb" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "devices" ]]; then
  if [[ -n "${MOCK_ADB_DEVICES:-}" ]]; then
    printf '%s\n' "$MOCK_ADB_DEVICES"
    exit 0
  fi
  cat <<'OUTPUT'
List of devices attached
192.168.70.125:5555    device
OUTPUT
  exit 0
fi
exit 0
EOF

cat >"$TEST_DIR/bin/scrcpy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  # Real scrcpy appends the upstream URL; the launcher must render only the
  # version field. MOCK_SCRCPY_VERSION=fail drives the probe-failure path.
  if [[ "${MOCK_SCRCPY_VERSION:-ok}" != "ok" ]]; then
    echo "mock scrcpy --version failure" >&2
    exit 3
  fi
  echo "scrcpy 4.1 <https://github.com/Genymobile/scrcpy>"
  exit 0
fi

case "${MOCK_SCRCPY_MODE:-}" in
  immediate)
    echo "mock scrcpy startup failure" >&2
    exit 42
    ;;
  delayed)
    sleep 0.75
    echo "mock delayed scrcpy failure" >&2
    exit 43
    ;;
  running)
    echo "mock scrcpy running"
    echo "$$" >"${MOCK_SCRCPY_PID_FILE}"
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    ;;
  stubborn)
    echo "mock scrcpy running"
    echo "$$" >"${MOCK_SCRCPY_PID_FILE}"
    # Swallows SIGTERM, so only the launcher's SIGKILL escalation can stop it.
    trap ':' TERM INT
    while :; do sleep 1; done
    ;;
  shape_shift)
    echo "mock scrcpy running"
    echo "$$" >"${MOCK_SCRCPY_PID_FILE}"
    # Ignores SIGTERM, but becomes a different program while keeping the same
    # PID. That is what a recycled PID looks like from the launcher's side, and
    # it is the only way to exercise the identity recheck the SIGKILL escalation
    # makes: the process outlives the grace period and is no longer scrcpy.
    trap 'exec sleep 300' TERM INT
    while :; do sleep 0.2; done
    ;;
  *)
    echo "unknown mock scrcpy mode" >&2
    exit 64
    ;;
esac
EOF

chmod +x "$TEST_DIR/bin/adb" "$TEST_DIR/bin/scrcpy"

run_launcher() {
  local mode=$1
  local tag=${2:-default}
  MOCK_SCRCPY_MODE="$mode" \
  MOCK_SCRCPY_PID_FILE="$TEST_DIR/scrcpy-$tag.pid" \
  MOCK_ADB_DEVICES="${MOCK_ADB_DEVICES:-}" \
  HOME="$TEST_DIR/home" \
  XDG_STATE_HOME="$TEST_DIR/state" \
  PATH="$TEST_DIR/bin:$PATH" \
    timeout 3s bash "$ROOT_DIR/scrcpy.sh" \
      --serial 192.168.70.125:5555 --args --no-audio 2>&1
}

# Device detection: no --serial, stdin closed so the prompt falls back to default.
run_detect() {
  local devices=$1
  local tag=${2:-detect}
  MOCK_SCRCPY_MODE=running \
  MOCK_SCRCPY_PID_FILE="$TEST_DIR/scrcpy-$tag.pid" \
  MOCK_ADB_DEVICES="$devices" \
  HOME="$TEST_DIR/home" \
  XDG_STATE_HOME="$TEST_DIR/state" \
  PATH="$TEST_DIR/bin:$PATH" \
    timeout 3s bash "$ROOT_DIR/scrcpy.sh" --args --no-audio </dev/null 2>&1
  local status=$?
  if [[ -s "$TEST_DIR/scrcpy-$tag.pid" ]]; then
    stop_pid "$(cat "$TEST_DIR/scrcpy-$tag.pid")"
  fi
  return $status
}

# `kill` is asynchronous: poll until the process is really gone, so that the
# next case is not refused by the launcher's still-alive PID guard.
wait_for_pid_gone() {
  local pid=${1:-} i
  [[ -n "$pid" ]] || return 0
  for i in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

# Stop a process a case started, unconditionally, and reap it. Safe to call
# with an empty or already-dead pid. Escalates to SIGKILL so that a mock which
# ignores SIGTERM cannot outlive the suite and orphan itself.
stop_pid() {
  local pid=${1:-}
  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || true
  if wait_for_pid_gone "$pid"; then
    return 0
  fi
  kill -9 "$pid" 2>/dev/null || true
  wait_for_pid_gone "$pid" || true
  return 0
}

# Stop everything a case may have left running, then drop the temp tree.
# Registered as the EXIT trap below, so a failing assertion still reaps the
# mocks it started instead of orphaning them.
cleanup() {
  local f pid
  for f in "$TEST_DIR"/scrcpy-*.pid "$TEST_DIR"/state*/adb-wireless-connect/scrcpy.pid; do
    [[ -s "$f" ]] || continue
    pid=$(cat "$f" 2>/dev/null) || pid=""
    stop_pid "$pid"
    rm -f "$f"
  done
  rm -rf "$TEST_DIR"
  return 0
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  [[ $# -ge 2 ]] && echo "$2" >&2
  exit 1
}

# Generic runner for the argument-handling cases: run_case <mode> <tag> <devices>
# [script args...]. Set MOCK_SCRCPY_VERSION in the caller's environment (use a
# command substitution so it does not leak between cases). Set CASE_STATE_HOME to
# give a case a private PID file and log directory. It is deliberately not
# XDG_STATE_HOME: an inherited value would point the launcher at the caller's
# real state directory, where the session guard could refuse (or --force kill)
# a genuinely running scrcpy.
run_case() {
  local mode=$1
  local tag=$2
  local devices=$3
  shift 3
  MOCK_SCRCPY_MODE="$mode" \
  MOCK_SCRCPY_VERSION="${MOCK_SCRCPY_VERSION:-ok}" \
  MOCK_SCRCPY_PID_FILE="$TEST_DIR/scrcpy-$tag.pid" \
  MOCK_ADB_DEVICES="$devices" \
  HOME="$TEST_DIR/home" \
  XDG_STATE_HOME="${CASE_STATE_HOME:-$TEST_DIR/state}" \
  PATH="$TEST_DIR/bin:$PATH" \
    timeout 3s bash "$ROOT_DIR/scrcpy.sh" "$@" </dev/null 2>&1
}

# Stop a backgrounded mock scrcpy left behind by a case that had to launch one.
# Unconditional: a case that fails its assertions must not orphan the process.
stop_mock_scrcpy() {
  local tag=$1
  if [[ -s "$TEST_DIR/scrcpy-$tag.pid" ]]; then
    stop_pid "$(cat "$TEST_DIR/scrcpy-$tag.pid")"
    rm -f "$TEST_DIR/scrcpy-$tag.pid"
  fi
  return 0
}

# Write a PID into the launcher's own PID file, the way a previous launch would.
# $1: state directory (defaults to the shared one), $2: pid to record.
seed_launcher_pid_file() {
  local state_dir=${1:-$TEST_DIR/state} pid=$2
  mkdir -p "$state_dir/adb-wireless-connect"
  printf '%s\n' "$pid" >"$state_dir/adb-wireless-connect/scrcpy.pid"
}

launcher_pid_file() {
  printf '%s\n' "${1:-$TEST_DIR/state}/adb-wireless-connect/scrcpy.pid"
}

# A private XDG_STATE_HOME, so a lifecycle case gets its own PID file and its
# own log directory instead of sharing one with every case before it.
new_state_dir() {
  local dir="$TEST_DIR/state-$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# Fill a log directory with $2 scrcpy.*.log files, all dated an hour into the
# future so every one of them is newer than the launch that follows. That makes
# the launch's own log the OLDEST of them all, which is the only arrangement in
# which "never delete the current log" is actually load-bearing.
seed_future_logs() {
  local dir=$1 count=$2 i base
  mkdir -p "$dir"
  base=$(( $(date +%s) + 3600 ))
  for i in $(seq 1 "$count"); do
    : >"$dir/scrcpy.seed$i.log"
    touch -d "@$(( base + i ))" "$dir/scrcpy.seed$i.log"
  done
}

extract_log_path() {
  sed $'s/\033\\[[0-9;]*m//g' | sed -n 's/.*Log: //p' | tail -n 1
}

output=$(run_launcher immediate)
status=$?
[[ $status -eq 42 ]] || fail "launcher returned $status for immediate failure; expected 42" "$output"
[[ "$output" == *"mock scrcpy startup failure"* ]] || fail "launcher hid the immediate scrcpy error" "$output"

output=$(run_launcher delayed)
status=$?
[[ $status -eq 43 ]] || fail "launcher returned $status for delayed failure; expected 43" "$output"
[[ "$output" == *"mock delayed scrcpy failure"* ]] || fail "launcher hid the delayed scrcpy error" "$output"

output=$(run_launcher running)
status=$?
[[ $status -eq 0 ]] || fail "launcher did not return after starting scrcpy in the background" "$output"
[[ "$output" == *"scrcpy started"* ]] || fail "launcher did not report the background process" "$output"
[[ -s "$TEST_DIR/scrcpy-default.pid" ]] || fail "mock scrcpy did not start" "$output"
scrcpy_pid=$(cat "$TEST_DIR/scrcpy-default.pid")
kill -0 "$scrcpy_pid" 2>/dev/null || fail "launcher did not leave scrcpy running" "$output"
log_file=$(extract_log_path <<<"$output")
[[ -s "$log_file" ]] || fail "launcher did not preserve the scrcpy output log" "$output"
grep -q "mock scrcpy running" "$log_file" || fail "scrcpy output log has unexpected content"
stop_pid "$scrcpy_pid"

# Two launches must not share a log. Task 3 makes a second live session a
# refusal, so the first session is stopped before the second one starts; the
# log-uniqueness guarantee is what this case is here to protect.
first_output=$(run_launcher running first)
first_pid=$(cat "$TEST_DIR/scrcpy-first.pid")
first_log=$(extract_log_path <<<"$first_output")
[[ -n "$first_log" ]] || fail "first launch did not report a log path" "$first_output"
stop_pid "$first_pid"

second_output=$(run_launcher running second)
second_pid=$(cat "$TEST_DIR/scrcpy-second.pid")
second_log=$(extract_log_path <<<"$second_output")
[[ -n "$second_log" ]] || fail "second launch did not report a log path" "$second_output"
[[ "$first_log" != "$second_log" ]] || fail "successive launches shared the same scrcpy log" "$first_output$second_output"
stop_pid "$second_pid"

# USB-only device must be detected, not rejected as "no wireless devices".
output=$(run_detect "List of devices attached
422ae881               device usb:2-3")
status=$?
[[ $status -eq 0 ]] || fail "USB-only device was not accepted (status $status)" "$output"
[[ "$output" == *"Device detected: 422ae881 (usb)"* ]] || fail "USB device serial was not detected" "$output"
[[ "$output" != *"No wireless ADB devices"* ]] || fail "launcher still reports wireless-only error" "$output"

# Mixed set: all transports listed, wireless sorted first and picked by default.
output=$(run_detect "List of devices attached
422ae881               device usb:2-3
192.168.70.125:5555    device
emulator-5554          device" mixed)
[[ "$output" == *"1) 192.168.70.125:5555  [wireless]"* ]] || fail "wireless device was not listed first" "$output"
[[ "$output" == *"2) 422ae881  [usb]"* ]] || fail "USB device was not listed" "$output"
[[ "$output" == *"3) emulator-5554  [emulator]"* ]] || fail "emulator device was not listed" "$output"
[[ "$output" == *"Selected device: 192.168.70.125:5555 (wireless)"* ]] || fail "default pick was not the wireless device" "$output"

# No devices at all: exits 1 with connection hints.
output=$(run_detect "List of devices attached
")
status=$?
[[ $status -eq 1 ]] || fail "empty device list returned $status; expected 1" "$output"
[[ "$output" == *"No connected ADB devices found (USB or wireless)"* ]] || fail "empty device list message is wrong" "$output"

# Unauthorized device must be named, with the RSA-prompt hint, not reported as "no devices".
output=$(run_detect "List of devices attached
422ae881               unauthorized usb:2-3")
status=$?
[[ $status -eq 1 ]] || fail "unauthorized device returned $status; expected 1" "$output"
[[ "$output" == *"422ae881 (unauthorized)"* ]] || fail "unauthorized device was not reported" "$output"
[[ "$output" == *"Allow USB debugging"* ]] || fail "unauthorized hint is missing" "$output"
[[ "$output" != *"No connected ADB devices found"* ]] || fail "unauthorized device was reported as absent" "$output"

# Offline device gets its own remediation.
output=$(run_detect "List of devices attached
192.168.70.125:5555    offline")
[[ "$output" == *"192.168.70.125:5555 (offline)"* ]] || fail "offline device was not reported" "$output"
[[ "$output" == *"replug the cable"* ]] || fail "offline hint is missing" "$output"

# A usable device still wins over a pending one.
output=$(run_detect "List of devices attached
422ae881               device usb:2-3
emulator-5554          offline")
[[ "$output" == *"Device detected: 422ae881 (usb)"* ]] || fail "usable device was not preferred over pending one" "$output"

# Missing adb binary is reported as such, not as "no devices".
# Mirror /usr/bin without adb (or scrcpy) so the rest of the script still works.
mkdir -p "$TEST_DIR/no-adb-bin"
for tool_path in /usr/bin/*; do
  tool=$(basename "$tool_path")
  [[ "$tool" == "adb" || "$tool" == "scrcpy" ]] && continue
  [[ -x "$tool_path" ]] || continue
  ln -sf "$tool_path" "$TEST_DIR/no-adb-bin/$tool" 2>/dev/null || true
done
out=$(env -i HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" \
  PATH="$TEST_DIR/no-adb-bin" timeout 3s bash "$ROOT_DIR/scrcpy.sh" </dev/null 2>&1)
status=$?
[[ $status -eq 1 ]] || fail "missing adb returned $status; expected 1" "$out"
[[ "$out" == *"adb not found"* ]] || fail "missing adb was not detected" "$out"
[[ "$out" != *"No connected ADB devices found"* ]] || fail "missing adb was misreported as no devices" "$out"

# --- Task 2: input handling, matching, and the version probe ----------------

WIRELESS_DEVICES="List of devices attached
192.168.70.125:5555    device"

# The serial is matched literally: '.' must not behave as a regex wildcard, so a
# lookalike serial does not satisfy --serial 1.2.3.4:5555.
output=$(run_case running nearmiss "List of devices attached
1x2y3z4:5555    device" --serial 1.2.3.4:5555 --args --no-audio)
status=$?
[[ $status -eq 1 ]] || fail "dotted serial matched a lookalike device (status $status)" "$output"
[[ "$output" == *"Specified device 1.2.3.4:5555 is not connected"* ]] || fail "lookalike serial was not rejected" "$output"
[[ "$output" != *"scrcpy started"* ]] || fail "launcher started scrcpy against a non-matching serial" "$output"

# A serial that really is present is still matched.
output=$(run_case running exactserial "$WIRELESS_DEVICES" --serial 192.168.70.125:5555 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "exact dotted serial was not accepted (status $status)" "$output"
[[ "$output" == *"Using specified device: 192.168.70.125:5555"* ]] || fail "exact serial was not used" "$output"
stop_mock_scrcpy exactserial

# -a may only be given once: a repeat inside the first batch is rejected.
output=$(run_case running dupargs "$WIRELESS_DEVICES" -a --no-audio -a --max-size=800)
status=$?
[[ $status -eq 1 ]] || fail "repeated -a was accepted (status $status)" "$output"
[[ "$output" == *"may only be given once"* ]] || fail "repeated -a message is missing" "$output"
[[ "$output" != *"scrcpy started"* ]] || fail "launcher proceeded despite a repeated -a" "$output"

# Even a bare repeat with nothing around it is rejected.
output=$(run_case running dupbare "$WIRELESS_DEVICES" -a -a)
status=$?
[[ $status -eq 1 ]] || fail "bare repeated -a was accepted (status $status)" "$output"
[[ "$output" == *"may only be given once"* ]] || fail "bare repeated -a message is missing" "$output"

# -s/--serial inside the batch is still rejected, with its own message.
output=$(run_case running innerargs "$WIRELESS_DEVICES" -a --no-audio -s 192.168.70.125:5555)
status=$?
[[ $status -eq 1 ]] || fail "-s inside --args was accepted (status $status)" "$output"
[[ "$output" == *"must come before -a/--args"* ]] || fail "-s inside --args message is missing" "$output"

# A single -a batch with several arguments is still accepted and forwarded.
output=$(run_case running singleargs "$WIRELESS_DEVICES" -a --no-audio --max-size=800)
status=$?
[[ $status -eq 0 ]] || fail "single -a batch was rejected (status $status)" "$output"
[[ "$output" == *"Args: --no-audio --max-size=800"* ]] || fail "arguments were not forwarded to scrcpy" "$output"
[[ "$output" == *"scrcpy started"* ]] || fail "launcher did not start with a single -a batch" "$output"
stop_mock_scrcpy singleargs

# A trailing --serial with no value must be reported, not crash on set -u.
output=$(run_case running noserial "$WIRELESS_DEVICES" --serial)
status=$?
[[ $status -eq 1 ]] || fail "bare trailing --serial returned $status; expected 1" "$output"
[[ "$output" == *"requires a device serial"* ]] || fail "trailing --serial message is missing" "$output"
[[ "$output" != *"unbound variable"* ]] || fail "trailing --serial died on an unbound variable under set -u" "$output"

# The detected version is reported, trimmed of the upstream URL.
output=$(run_case running versionok "$WIRELESS_DEVICES" --serial 192.168.70.125:5555 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "launcher failed while reporting the version (status $status)" "$output"
[[ "$output" == *"scrcpy detected (version 4.1)"* ]] || fail "scrcpy version was not reported" "$output"
[[ "$output" != *"github.com"* ]] || fail "the version line leaked the scrcpy --version URL" "$output"
stop_mock_scrcpy versionok

# A failing version probe warns and continues; it must not abort the launch.
output=$(MOCK_SCRCPY_VERSION=fail run_case running versionfail "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "failing version probe aborted the launch (status $status)" "$output"
[[ "$output" == *"Could not determine the scrcpy version"* ]] || fail "failing version probe did not warn" "$output"
[[ "$output" == *"scrcpy started"* ]] || fail "launcher did not proceed after a version probe failure" "$output"
stop_mock_scrcpy versionfail

echo "PASS: launcher reports startup failures, isolates background launch logs, and detects USB devices"
echo "PASS: launcher matches serials literally, rejects repeated -a/--args, and reports the scrcpy version"

# --- Task 3: session lifecycle, --force, and log retention ----------------------

# The three new flags are part of the documented surface. Match the option-list
# lines ("-w, --wait"), not the bare flag name: the notes below the list also
# mention --wait, so a bare-name check would pass with the option line deleted.
help_out=$(HOME="$TEST_DIR/home" PATH="$TEST_DIR/bin:$PATH" \
  bash "$ROOT_DIR/scrcpy.sh" --help 2>&1)
help_status=$?
[[ $help_status -eq 0 ]] || fail "--help exited $help_status; expected 0" "$help_out"
for option in "-t, --timeout" "-w, --wait" "-f, --force"; do
  [[ "$help_out" == *"$option"* ]] || fail "$option is not documented in --help" "$help_out"
done

# The help names the grace period twice: once as the default in the option list
# and once as the value this run will use. Both must come from the same source,
# because --timeout is parsed before -h can print anything. When the two were
# independent, `--timeout 5 --help` printed "default: 2" and "waits 5 seconds" in
# one help text with nothing to say they were different quantities.
help_after=$(HOME="$TEST_DIR/home" PATH="$TEST_DIR/bin:$PATH" \
  bash "$ROOT_DIR/scrcpy.sh" --timeout 5 --help 2>&1)
help_after_status=$?
[[ $help_after_status -eq 0 ]] || fail "--help after --timeout exited $help_after_status; expected 0" "$help_after"
[[ "$help_after" == *"(default: 2)"* ]] ||
  fail "--help after --timeout 5 does not report the real default" "$help_after"
[[ "$help_after" == *"waits 5 seconds"* ]] ||
  fail "--help after --timeout 5 does not report the effective grace period" "$help_after"
# Without this the two lines above are back to reading as a contradiction.
[[ "$help_after" == *"defaults to 2 seconds"* ]] ||
  fail "--help does not distinguish the default from the effective grace period" "$help_after"
# The reverse error: reporting the effective value as if it were the default.
[[ "$help_after" != *"default: 5"* ]] ||
  fail "--help reported the effective --timeout as the default" "$help_after"
[[ "$help_after" != *"defaults to 5 seconds"* ]] ||
  fail "--help reported the effective --timeout as the default" "$help_after"

# --timeout rejects anything that is not a positive number of seconds. The
# format check is what rejects a negative, so no separate case is needed.
for bad_timeout in abc -1 1e3 2s; do
  output=$(run_case running "badto$bad_timeout" "$WIRELESS_DEVICES" \
    --serial 192.168.70.125:5555 --timeout "$bad_timeout" --args --no-audio)
  status=$?
  [[ $status -eq 1 ]] || fail "--timeout $bad_timeout returned $status; expected 1" "$output"
  [[ "$output" == *"must be a positive number of seconds"* ]] ||
    fail "--timeout $bad_timeout was not rejected as a bad value" "$output"
  [[ "$output" != *"scrcpy started"* ]] || fail "scrcpy ran despite --timeout $bad_timeout" "$output"
done

# Zero is a well-formed number but means "no grace period at all", which would
# race a healthy slow start, so it is rejected separately.
for zero_timeout in 0 0.0 0.00; do
  output=$(run_case running "zeroto$zero_timeout" "$WIRELESS_DEVICES" \
    --serial 192.168.70.125:5555 --timeout "$zero_timeout" --args --no-audio)
  status=$?
  [[ $status -eq 1 ]] || fail "--timeout $zero_timeout returned $status; expected 1" "$output"
  [[ "$output" == *"must be greater than zero"* ]] ||
    fail "--timeout $zero_timeout was not rejected as non-positive" "$output"
done

# A trailing --timeout with no value must be reported, not crash on set -u. It
# cannot be combined with --args: -a swallows the rest of the command line.
output=$(run_case running tobare "$WIRELESS_DEVICES" --serial 192.168.70.125:5555 --timeout)
status=$?
[[ $status -eq 1 ]] || fail "bare trailing --timeout returned $status; expected 1" "$output"
[[ "$output" == *"requires a grace period in seconds"* ]] || fail "trailing --timeout message is missing" "$output"
[[ "$output" != *"unbound variable"* ]] || fail "trailing --timeout died on an unbound variable" "$output"

# A short grace period is accepted and really is short. The delayed mock lives
# 0.75s and exits 43, which the 2s default above already saw die; at 0.2s it is
# still alive, so this launch succeeds. No wall-clock bound is asserted: the old
# `elapsed <= 1` was measured in whole $SECONDS against a 0.55s margin, so it
# failed on a loaded machine and could not be made meaningful by loosening it.
# Status 0 with "scrcpy started" is the discriminating pair — the 2s default
# returns 43 for this same mock, so both are pinned by cases above and below.
output=$(run_case delayed shorttimeout "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --timeout 0.2 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "a 0.2s grace period refused a healthy start (status $status)" "$output"
[[ "$output" == *"scrcpy started"* ]] || fail "a short --timeout did not start scrcpy" "$output"

# A live PID in the launcher's PID file is a deliberate refusal.
refuse_state=$(new_state_dir refuse)
output=$(CASE_STATE_HOME="$refuse_state" run_case running refusea "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "the first launch of a session failed (status $status)" "$output"
[[ -s "$TEST_DIR/scrcpy-refusea.pid" ]] || fail "the first launch started no scrcpy" "$output"
running_pid=$(cat "$TEST_DIR/scrcpy-refusea.pid")
# The mock is a `#!/usr/bin/env bash` script, so the kernel-set argv names an
# interpreter before it names scrcpy. Pin that premise here: it is the reason a
# fixed argv[0]-or-argv[1] window would be a regression rather than a
# simplification, and without this check the refusal below would still "pass" on
# a checker that never found the session at all — nothing to refuse, nothing to
# replace, and the case green for the wrong reason.
refuse_argv0=$(tr '\0' '\n' <"/proc/$running_pid/cmdline" 2>/dev/null | head -n 1)
[[ -n "$refuse_argv0" ]] || fail "the first session's command line could not be read" "$output"
[[ "${refuse_argv0##*/}" != "scrcpy" ]] ||
  fail "the mock's identity is at argv[0]; this harness no longer covers a wrapped scrcpy" "$output"
refuse_pid_file=$(launcher_pid_file "$refuse_state")
[[ -f "$refuse_pid_file" ]] || fail "the launch wrote no PID file" "$output"
[[ "$(cat "$refuse_pid_file")" == "$running_pid" ]] ||
  fail "the PID file does not name the running scrcpy" "$output"
[[ "$output" == *"PID file: $refuse_pid_file"* ]] ||
  fail "the launch did not print the PID file path" "$output"

# Rewrite the PID file with no trailing newline: `read` returns non-zero for
# such a file even though it assigns the value, and a `|| recorded=""` style
# fallback would silently discard the PID and let this launch through.
printf '%s' "$running_pid" >"$refuse_pid_file"
output=$(CASE_STATE_HOME="$refuse_state" run_case running refuseb "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 1 ]] || fail "a second live session was allowed (status $status)" "$output"
[[ "$output" == *"already running (PID: $running_pid)"* ]] ||
  fail "the refusal does not name the running PID" "$output"
[[ "$output" == *"kill $running_pid"* ]] || fail "the refusal does not print the kill command" "$output"
[[ "$output" == *"--force"* ]] || fail "the refusal does not mention --force" "$output"
[[ "$output" != *"scrcpy started"* ]] || fail "a refused launch still started scrcpy" "$output"
[[ ! -e "$TEST_DIR/scrcpy-refuseb.pid" ]] || fail "a refused launch started a second scrcpy" "$output"
kill -0 "$running_pid" 2>/dev/null || fail "the refused launch killed the running session" "$output"

# --force stops the recorded session and starts a new one.
output=$(CASE_STATE_HOME="$refuse_state" run_case running refuser "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --force --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "--force did not start a new session (status $status)" "$output"
[[ "$output" == *"--force"* ]] || fail "--force did not report that it stopped a session" "$output"
[[ "$output" == *"(PID: $running_pid)"* ]] || fail "--force did not name the PID it stopped" "$output"
# Assert before cleaning up: the launcher only returns after _wait_for_exit has
# seen the old process go, so a live PID here means --force did not stop it.
if kill -0 "$running_pid" 2>/dev/null; then
  fail "--force left the old session (PID $running_pid) running" "$output"
fi
stop_pid "$running_pid"
[[ -s "$TEST_DIR/scrcpy-refuser.pid" ]] || fail "--force started no new scrcpy" "$output"
forced_pid=$(cat "$TEST_DIR/scrcpy-refuser.pid")
[[ "$forced_pid" != "$running_pid" ]] || fail "--force reused the stopped session" "$output"
[[ "$(cat "$refuse_pid_file")" == "$forced_pid" ]] || fail "--force did not repoint the PID file" "$output"
kill -0 "$forced_pid" 2>/dev/null || fail "--force did not leave the new session running" "$output"
stop_mock_scrcpy refuser

# --force must also stop a session that ignores SIGTERM, which is what the
# SIGKILL escalation in the launcher is for.
stubborn_state=$(new_state_dir stubborn)
output=$(CASE_STATE_HOME="$stubborn_state" run_case stubborn stubborn "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "the launch of a SIGTERM-proof session failed (status $status)" "$output"
[[ -s "$TEST_DIR/scrcpy-stubborn.pid" ]] || fail "the SIGTERM-proof session did not start" "$output"
stubborn_pid=$(cat "$TEST_DIR/scrcpy-stubborn.pid")
output=$(CASE_STATE_HOME="$stubborn_state" run_case running stubborn2 "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --force --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "--force could not replace a session that ignores SIGTERM (status $status)" "$output"
if kill -0 "$stubborn_pid" 2>/dev/null; then
  fail "--force left a SIGTERM-proof session (PID $stubborn_pid) running" "$output"
fi
stop_mock_scrcpy stubborn2

# A process that stops being scrcpy while the launcher is waiting for it to
# exit must not be SIGKILLed. This is the escalation path, one function away from
# the identity gate that guards the first signal, and it is the one place a
# SIGTERM-proof process can be confused with a recycled PID. The mock turns
# itself into `sleep 300` in the same PID when signalled, so a launcher without
# the recheck kills an innocent process and reports a clean --force; one with the
# recheck refuses and hands the PID back to the user.
shift_state=$(new_state_dir shift)
output=$(CASE_STATE_HOME="$shift_state" run_case shape_shift shift "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "the launch of a shape-shifting session failed (status $status)" "$output"
[[ -s "$TEST_DIR/scrcpy-shift.pid" ]] || fail "the shape-shifting session did not start" "$output"
shift_pid=$(cat "$TEST_DIR/scrcpy-shift.pid")
output=$(CASE_STATE_HOME="$shift_state" run_case running shift2 "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --force --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 1 ]] ||
  fail "--force reported success against a PID that stopped being scrcpy (status $status)" "$output"
[[ "$output" == *"Could not stop the scrcpy session (PID: $shift_pid)"* ]] ||
  fail "the failed --force does not name the PID it refused to kill" "$output"
[[ "$output" == *"kill -9 $shift_pid"* ]] || fail "the failed --force gives no next step" "$output"
[[ "$output" != *"scrcpy started"* ]] ||
  fail "--force started a new session over a PID it could not stop" "$output"
kill -0 "$shift_pid" 2>/dev/null ||
  fail "the SIGKILL escalation killed a process that was no longer scrcpy" "$output"
stop_mock_scrcpy shift
stop_pid "$shift_pid"

# A PID file whose process is gone is stale: it must not block a launch, and it
# must be overwritten.
stale_state=$(new_state_dir stale)
sleep 0.1 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
seed_launcher_pid_file "$stale_state" "$dead_pid"
output=$(CASE_STATE_HOME="$stale_state" run_case running stale "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "a stale PID file blocked the launch (status $status)" "$output"
[[ "$output" != *"already running"* ]] || fail "a stale PID file was treated as a live session" "$output"
[[ "$output" == *"scrcpy started"* ]] || fail "the launch over a stale PID file did not start scrcpy" "$output"
[[ -s "$TEST_DIR/scrcpy-stale.pid" ]] || fail "the launch over a stale PID file started no scrcpy" "$output"
stale_live_pid=$(cat "$TEST_DIR/scrcpy-stale.pid")
[[ "$(cat "$(launcher_pid_file "$stale_state")")" == "$stale_live_pid" ]] ||
  fail "the stale PID file was not overwritten with the new session" "$output"
stop_mock_scrcpy stale

# The PID file is only removed on a clean --wait exit or a detected startup
# failure, so a SIGKILLed launcher, a reboot, or a plain scrcpy quit all strand
# it and the number in it can be recycled by an unrelated process. Liveness is
# not identity: a live process that is not scrcpy must be treated as stale.
foreign_state=$(new_state_dir foreign)
sleep 300 &
foreign_pid=$!
# Registered under the pid-file glob the EXIT trap reaps, so a failing
# assertion here cannot orphan it either.
printf '%s\n' "$foreign_pid" >"$TEST_DIR/scrcpy-foreignhold.pid"
kill -0 "$foreign_pid" 2>/dev/null || fail "the stand-in process did not start"
seed_launcher_pid_file "$foreign_state" "$foreign_pid"
output=$(CASE_STATE_HOME="$foreign_state" run_case running foreign "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "a live non-scrcpy PID blocked the launch (status $status)" "$output"
[[ "$output" != *"already running"* ]] ||
  fail "a live non-scrcpy PID was reported as a scrcpy session" "$output"
[[ "$output" == *"scrcpy started"* ]] || fail "the launch over an unidentifiable PID file did not start" "$output"
kill -0 "$foreign_pid" 2>/dev/null || fail "the launch killed an unrelated process" "$output"
[[ -s "$TEST_DIR/scrcpy-foreign.pid" ]] || fail "the launch over an unidentifiable PID file started nothing" "$output"
[[ "$(cat "$TEST_DIR/scrcpy-foreign.pid")" != "$foreign_pid" ]] ||
  fail "the unidentifiable PID file was not overwritten" "$output"
stop_mock_scrcpy foreign

# --force must not signal a process it has not identified as scrcpy either.
seed_launcher_pid_file "$foreign_state" "$foreign_pid"
output=$(CASE_STATE_HOME="$foreign_state" run_case running foreignf "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --force --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "--force refused over an unidentifiable PID (status $status)" "$output"
[[ "$output" != *"--force given"* ]] ||
  fail "--force claimed to stop a process it never identified as scrcpy" "$output"
[[ "$output" == *"scrcpy started"* ]] || fail "--force did not start a new session" "$output"
kill -0 "$foreign_pid" 2>/dev/null || fail "--force killed an unrelated process" "$output"
stop_mock_scrcpy foreignf
stop_pid "$foreign_pid"

# A live process whose command line *mentions* scrcpy without being scrcpy: argv[0]
# is an unrelated real program and "scrcpy" is only an argument, exactly like
# `find / -name scrcpy` or `vim scrcpy`. The identity check used to search every
# argv field, so this was positively identified as a live session and --force
# SIGTERMed and then SIGKILLed it. `yes` needs no mock, takes the argument
# without complaint, and stays alive for the length of the case.
mention_state=$(new_state_dir mention)
yes scrcpy >/dev/null 2>&1 &
mention_pid=$!
# Registered under the pid-file glob the EXIT trap reaps, so a failing assertion
# here cannot orphan it either.
printf '%s\n' "$mention_pid" >"$TEST_DIR/scrcpy-mentionhold.pid"
kill -0 "$mention_pid" 2>/dev/null || fail "the stand-in process did not start"
# Pin the premise rather than trust it: scrcpy must really be a non-leading argv
# entry, or this case would stop testing the walk and start testing liveness.
# A forked background job still shows its parent's command line until execve
# completes, so read with a short retry rather than racing the exec — the
# launcher's own identity reads never race, because they happen at least one
# grace period after the PID was recorded.
parent_cmdline=$(tr '\0' ' ' <"/proc/$$/cmdline" 2>/dev/null)
mention_argv=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
  mention_argv=$(tr '\0' ' ' <"/proc/$mention_pid/cmdline" 2>/dev/null)
  [[ -n "$mention_argv" && "$mention_argv" != "$parent_cmdline" ]] && break
  sleep 0.1
done
case "$mention_argv" in
  yes\ scrcpy*) : ;;
  *) fail "the stand-in does not have scrcpy as a non-leading argv entry" "$mention_argv" ;;
esac
seed_launcher_pid_file "$mention_state" "$mention_pid"
output=$(CASE_STATE_HOME="$mention_state" run_case running mention "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "a PID file naming scrcpy as an argument blocked the launch (status $status)" "$output"
[[ "$output" != *"already running"* ]] ||
  fail "a process that merely mentions scrcpy was reported as a scrcpy session" "$output"
[[ "$output" == *"scrcpy started"* ]] ||
  fail "the launch over a scrcpy-mentioning PID file did not start" "$output"
kill -0 "$mention_pid" 2>/dev/null ||
  fail "the launch signalled a process that only mentions scrcpy" "$output"
stop_mock_scrcpy mention

# --force must not escalate to signals on it either.
seed_launcher_pid_file "$mention_state" "$mention_pid"
output=$(CASE_STATE_HOME="$mention_state" run_case running mentionf "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --force --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "--force refused over a PID that only mentions scrcpy (status $status)" "$output"
[[ "$output" != *"--force given"* ]] ||
  fail "--force claimed to stop a process whose executable is not scrcpy" "$output"
[[ "$output" == *"scrcpy started"* ]] || fail "--force did not start a new session" "$output"
kill -0 "$mention_pid" 2>/dev/null ||
  fail "--force killed a process that only mentions scrcpy" "$output"
stop_mock_scrcpy mentionf
stop_pid "$mention_pid"

# --wait hands scrcpy's own status back and takes the PID file with it. The
# seeded PID file proves the file was written and then removed, rather than
# never having existed.
wait_state=$(new_state_dir wait)
sleep 0.1 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
seed_launcher_pid_file "$wait_state" "$dead_pid"
output=$(CASE_STATE_HOME="$wait_state" run_case immediate wait42 "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --wait --args --no-audio)
status=$?
[[ $status -eq 42 ]] || fail "--wait returned $status for a scrcpy that exited 42" "$output"
[[ "$output" == *"scrcpy exited with status: 42"* ]] || fail "--wait did not report scrcpy's status" "$output"
[[ "$output" == *"mock scrcpy startup failure"* ]] || fail "--wait hid the scrcpy output" "$output"
[[ ! -e "$(launcher_pid_file "$wait_state")" ]] || fail "--wait left the PID file behind" "$output"
wait_log=$(extract_log_path <<<"$output")
[[ -s "$wait_log" ]] || fail "--wait did not capture the scrcpy output in its log" "$output"

# The same path with a mock that lives 0.75s first: the launcher can only report
# 43 by having blocked until that mock exited, so this is the proof that --wait
# waits rather than backgrounding.
output=$(CASE_STATE_HOME="$wait_state" run_case delayed wait43 "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --wait --args --no-audio)
status=$?
[[ $status -eq 43 ]] || fail "--wait returned $status for a scrcpy that exited 43" "$output"
[[ "$output" == *"scrcpy exited with status: 43"* ]] || fail "--wait did not report the later status" "$output"
[[ ! -e "$(launcher_pid_file "$wait_state")" ]] || fail "--wait left the PID file behind" "$output"

# Log retention: the newest 10 scrcpy.*.log files survive, the rest are deleted,
# and the current launch's log survives even when it is the oldest of them all.
prune_state=$(new_state_dir prune)
prune_dir="$prune_state/adb-wireless-connect"
seed_future_logs "$prune_dir" 15
output=$(CASE_STATE_HOME="$prune_state" run_case running prune "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 0 ]] || fail "the launch for the pruning case failed (status $status)" "$output"
prune_log=$(extract_log_path <<<"$output")
[[ -s "$prune_log" ]] || fail "the current launch's log was pruned away" "$output"
grep -q "mock scrcpy running" "$prune_log" || fail "the surviving log is not the current launch's"
kept_count=$(ls -1 "$prune_dir"/scrcpy.*.log | wc -l)
[[ $kept_count -eq 11 ]] ||
  fail "log directory holds $kept_count files; expected the current log plus 10 kept" "$output"
for i in $(seq 1 5); do
  [[ ! -e "$prune_dir/scrcpy.seed$i.log" ]] || fail "an old log (seed$i) was not pruned" "$output"
done
for i in $(seq 6 15); do
  [[ -e "$prune_dir/scrcpy.seed$i.log" ]] || fail "a recent log (seed$i) was pruned" "$output"
done
stop_mock_scrcpy prune

# A launch that fails is exactly the case where a user retries, so the log
# directory has to stay bounded on the failure path too.
failprune_state=$(new_state_dir failprune)
failprune_dir="$failprune_state/adb-wireless-connect"
seed_future_logs "$failprune_dir" 15
output=$(CASE_STATE_HOME="$failprune_state" run_case immediate failprune "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 42 ]] || fail "the failing launch for the prune case returned $status; expected 42" "$output"
failed_prune_log=$(extract_log_path <<<"$output")
[[ -s "$failed_prune_log" ]] || fail "the failed launch's own log was pruned away" "$output"
failed_kept=$(ls -1 "$failprune_dir"/scrcpy.*.log | wc -l)
[[ $failed_kept -eq 11 ]] ||
  fail "a failed launch left $failed_kept logs; expected the current log plus 10 kept" "$output"
[[ ! -e "$failprune_dir/scrcpy.seed1.log" ]] || fail "a failed launch did not prune an old log" "$output"
[[ -e "$failprune_dir/scrcpy.seed15.log" ]] || fail "a failed launch pruned a recent log" "$output"

# A state directory that cannot be written must be reported as itself, not as a
# scrcpy startup failure. A regular file where the directory should be makes
# mkdir and mktemp fail the same way on any uid, root included.
printf 'not a directory\n' >"$TEST_DIR/blocker"
output=$(CASE_STATE_HOME="$TEST_DIR/blocker" run_case running blocked "$WIRELESS_DEVICES" \
  --serial 192.168.70.125:5555 --timeout 0.3 --args --no-audio)
status=$?
[[ $status -eq 1 ]] || fail "an unwritable state directory returned $status; expected 1" "$output"
[[ "$output" == *"Could not create a log file"* ]] ||
  fail "an unwritable state directory was not reported" "$output"
[[ "$output" == *"ls -ld"* ]] || fail "the unwritable-directory message gives no next step" "$output"
[[ "$output" != *"scrcpy failed to start"* ]] ||
  fail "an unwritable state directory was misreported as a scrcpy failure" "$output"
[[ ! -e "$TEST_DIR/scrcpy-blocked.pid" ]] || fail "an unwritable state directory still started scrcpy" "$output"

# A state directory where the log can be created but the PID file cannot be
# written must be reported as itself. Both writes sit inside functions main calls
# as `||` operands, and bash suspends errexit across the whole dynamic extent of
# such a function, so neither one was protected by `set -e` — the launcher
# printed "[✓] scrcpy started" and a PID path with no PID file behind it.
# /dev/full arranges exactly that, uid-independently: it opens, then every write
# fails with ENOSPC, so mktemp still succeeds and only the PID write breaks. A
# chmod would not survive a root run, and a directory at scrcpy.pid would fail
# earlier in the `[[ -s ]]`/read path for a different reason entirely.
if [[ -c /dev/full ]] && : >/dev/full 2>/dev/null; then
  pidfail_state=$(new_state_dir pidfail)
  mkdir -p "$pidfail_state/adb-wireless-connect"
  ln -s /dev/full "$pidfail_state/adb-wireless-connect/scrcpy.pid"
  output=$(CASE_STATE_HOME="$pidfail_state" run_case running pidfail "$WIRELESS_DEVICES" \
    --serial 192.168.70.125:5555 --timeout 0.3 --args --no-audio)
  status=$?
  [[ $status -eq 1 ]] || fail "a failed PID-file write returned $status; expected 1" "$output"
  [[ "$output" == *"Could not write the PID file"* ]] ||
    fail "a failed PID-file write was not reported" "$output"
  [[ "$output" == *"ls -ld"* ]] || fail "the failed PID-write message gives no next step" "$output"
  [[ "$output" != *"scrcpy started"* ]] ||
    fail "a launch whose PID file could not be written reported success" "$output"
  # The success line's own shape, newline-anchored: the failure message names the
  # path too, but never in the launcher's "    PID file: <path>" form.
  [[ "$output" != *$'\n'"    PID file: "* ]] ||
    fail "a failed PID write still printed the success line's PID file path" "$output"
  # A session the launcher cannot record is stopped rather than left invisible.
  # The mock may not have reached its own PID file before the signal, so this
  # only asserts when there is something to assert about.
  if [[ -s "$TEST_DIR/scrcpy-pidfail.pid" ]]; then
    wait_for_pid_gone "$(cat "$TEST_DIR/scrcpy-pidfail.pid")" ||
      fail "a launch that could not record its PID left scrcpy running" "$output"
  fi
  stop_mock_scrcpy pidfail

  # The same write in --wait mode, reached through _launch_and_wait, which is
  # called as `_launch_and_wait … || return $?` and is therefore just as
  # errexit-free. Unguarded it would not even report a failure: the launcher
  # would block on a session it can never record, and only the harness's 3s
  # timeout would end the run.
  pidfailwait_state=$(new_state_dir pidfailwait)
  mkdir -p "$pidfailwait_state/adb-wireless-connect"
  ln -s /dev/full "$pidfailwait_state/adb-wireless-connect/scrcpy.pid"
  output=$(CASE_STATE_HOME="$pidfailwait_state" run_case running pidfailwait "$WIRELESS_DEVICES" \
    --serial 192.168.70.125:5555 --wait --args --no-audio)
  status=$?
  [[ $status -eq 1 ]] || fail "a failed PID-file write in --wait mode returned $status; expected 1" "$output"
  [[ "$output" == *"Could not write the PID file"* ]] ||
    fail "a failed PID-file write in --wait mode was not reported" "$output"
  [[ "$output" != *"scrcpy exited"* ]] ||
    fail "--wait reported a session exit for a session it never recorded" "$output"
  if [[ -s "$TEST_DIR/scrcpy-pidfailwait.pid" ]]; then
    wait_for_pid_gone "$(cat "$TEST_DIR/scrcpy-pidfailwait.pid")" ||
      fail "--wait left scrcpy running after failing to record its PID" "$output"
  fi
  stop_mock_scrcpy pidfailwait
else
  echo "SKIP: failed PID-file write cases need /dev/full"
fi

# A zero-padded answer at the device picker (08) must not be read as an invalid
# octal number. The picker reads /dev/tty, so this case needs a real pty; util-
# linux `script` is the cheapest way to get one.
if command -v script >/dev/null; then
  picker_state=$(new_state_dir picker)
  picker_devices="List of devices attached"
  for i in 125 126 127 128 129 130 131 132; do
    picker_devices="$picker_devices
192.168.70.$i:5555    device"
  done
  # Built with printf -q, like tests/test_start_stop.sh's pty helper: the device
  # list is multi-line and %q is what survives it as one argument. Raw
  # single-quote interpolation happened to work only because no mock device list
  # contains a quote.
  printf -v picker_cmd 'env HOME=%q XDG_STATE_HOME=%q PATH=%q MOCK_SCRCPY_MODE=%q MOCK_SCRCPY_PID_FILE=%q MOCK_ADB_DEVICES=%q timeout 3s bash %q --args --no-audio --timeout 0.3' \
    "$TEST_DIR/home" "$picker_state" "$TEST_DIR/bin:$PATH" running \
    "$TEST_DIR/scrcpy-picker.pid" "$picker_devices" "$ROOT_DIR/scrcpy.sh"
  output=$(printf '08\n' | script -qec "$picker_cmd" /dev/null 2>&1)
  status=$?
  [[ $status -eq 0 ]] || fail "a zero-padded device choice killed the launcher (status $status)" "$output"
  [[ "$output" == *"Selected device: 192.168.70.132:5555"* ]] ||
    fail "device choice 08 did not select the eighth device" "$output"
  [[ "$output" != *"value too great for base"* ]] ||
    fail "device choice 08 was read as an octal number" "$output"
  stop_mock_scrcpy picker
else
  echo "SKIP: zero-padded device-picker case needs util-linux 'script' for a pty"
fi

echo "PASS: launcher validates --timeout, guards and overrides a live session, propagates --wait status, and bounds the log directory"
echo "PASS: launcher trusts a PID file only when /proc identifies it as scrcpy, and bounds the log directory on failure too"

