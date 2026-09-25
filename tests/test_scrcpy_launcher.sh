#!/usr/bin/env bash
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home" "$TEST_DIR/state"

cat >"$TEST_DIR/bin/adb" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "devices" ]]; then
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
  echo "scrcpy 4.1"
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
  HOME="$TEST_DIR/home" \
  XDG_STATE_HOME="$TEST_DIR/state" \
  PATH="$TEST_DIR/bin:$PATH" \
    timeout 3s bash "$ROOT_DIR/scrcpy.sh" \
      --serial 192.168.70.125:5555 --args --no-audio 2>&1
}

fail() {
  echo "FAIL: $1" >&2
  [[ $# -ge 2 ]] && echo "$2" >&2
  exit 1
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

echo "PASS: launcher reports startup failures and isolates background launch logs"
