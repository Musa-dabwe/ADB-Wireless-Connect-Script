#!/usr/bin/env bash
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

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
    kill "$(cat "$TEST_DIR/scrcpy-$tag.pid")" 2>/dev/null || true
  fi
  return $status
}

fail() {
  echo "FAIL: $1" >&2
  [[ $# -ge 2 ]] && echo "$2" >&2
  exit 1
}

# Generic runner for the argument-handling cases: run_case <mode> <tag> <devices>
# [script args...]. Set MOCK_SCRCPY_VERSION in the caller's environment (use a
# command substitution so it does not leak between cases).
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
  XDG_STATE_HOME="$TEST_DIR/state" \
  PATH="$TEST_DIR/bin:$PATH" \
    timeout 3s bash "$ROOT_DIR/scrcpy.sh" "$@" </dev/null 2>&1
}

# Stop a backgrounded mock scrcpy left behind by a case that had to launch one.
stop_mock_scrcpy() {
  local tag=$1
  if [[ -s "$TEST_DIR/scrcpy-$tag.pid" ]]; then
    kill "$(cat "$TEST_DIR/scrcpy-$tag.pid")" 2>/dev/null || true
    rm -f "$TEST_DIR/scrcpy-$tag.pid"
  fi
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
kill "$scrcpy_pid" 2>/dev/null || true

first_output=$(run_launcher running first)
second_output=$(run_launcher running second)
first_pid=$(cat "$TEST_DIR/scrcpy-first.pid")
second_pid=$(cat "$TEST_DIR/scrcpy-second.pid")
first_log=$(extract_log_path <<<"$first_output")
second_log=$(extract_log_path <<<"$second_output")
[[ -n "$first_log" && -n "$second_log" ]] || fail "concurrent launches did not report log paths" "$first_output$second_output"
[[ "$first_log" != "$second_log" ]] || fail "concurrent launches shared the same scrcpy log" "$first_output$second_output"
kill "$first_pid" "$second_pid" 2>/dev/null || true

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
