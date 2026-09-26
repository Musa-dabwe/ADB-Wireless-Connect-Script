#!/usr/bin/env bash
set -u

# Regression suite for start.sh and stop.sh. Follows tests/test_scrcpy_launcher.sh:
# mock adb / ping / sleep on PATH, driven by MOCK_* variables, one runner per
# script, and a visible PASS line per case group at the end.
#
# Two properties this harness guarantees:
#   * No case can reach a real device. adb is the only way either script touches
#     hardware, and it is shadowed by a mock for every case.
#   * No case can leave a process running. Every child is a foreground `timeout`
#     in a command substitution, so nothing is backgrounded to begin with — see
#     cleanup for why there is no pid sweep.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
BASE_PATH=$PATH

# Clear every mock knob the suite knows about, before any case runs. Inside the
# runners `${MOCK_X:-default}` honours a case's own prefix assignment
# (`MOCK_ADB_CONNECT=fail run_script …`) and falls back to the default
# otherwise — but a knob the developer happened to have exported
# (`MOCK_ADB_CONNECT=fail bash tests/test_start_stop.sh`) is indistinguishable
# from such an assignment once the function is running, and would silently drive
# every case with no override of its own into the failure path. Scrubbing here
# makes "a value can only come from the case that wanted it" true.
for knob in MOCK_ADB_DEVICES MOCK_ADB_SHELL_ADDR MOCK_ADB_PAIR MOCK_ADB_CONNECT \
  MOCK_ADB_KILL_SERVER MOCK_ADB_DISCONNECT_FAIL MOCK_PING MOCK_PING_FAIL \
  MOCK_ADB_CALL_LOG MOCK_SLEEP_LOG; do
  unset "$knob"
done

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home"

# --- mocks -------------------------------------------------------------------

cat >"$TEST_DIR/bin/adb" <<'EOF'
#!/usr/bin/env bash
# Mock adb with two jobs:
#   1. Record the exact command line of every invocation, so a case can assert on
#      what the script under test asked adb to do, and how many times.
#   2. Answer from MOCK_* so each case picks the outcome it needs.
if [[ -n "${MOCK_ADB_CALL_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$MOCK_ADB_CALL_LOG"
fi

# `adb -s <serial> <subcommand> ...` is the device-scoped form both scripts use
# for tcpip and shell; strip it so the dispatch below only knows subcommands.
args=("$@")
if [[ "${args[0]:-}" == "-s" && ${#args[@]} -ge 3 ]]; then
  args=("${args[@]:2}")
fi
cmd=${args[0]:-}

case "$cmd" in
  devices)
    if [[ -n "${MOCK_ADB_DEVICES:-}" ]]; then
      printf '%s\n' "$MOCK_ADB_DEVICES"
    else
      printf 'List of devices attached\n'
    fi
    exit 0
    ;;
  start-server) exit 0 ;;
  kill-server)
    if [[ "${MOCK_ADB_KILL_SERVER:-ok}" == "fail" ]]; then
      echo "error: failed to kill server" >&2
      exit 1
    fi
    exit 0
    ;;
  pair)
    if [[ "${MOCK_ADB_PAIR:-ok}" == "fail" ]]; then
      echo "error: failed to pair to ${args[1]:-}"
      exit 1
    fi
    echo "Successfully paired to ${args[1]:-}"
    exit 0
    ;;
  connect)
    target=${args[1]:-}
    if [[ "${MOCK_ADB_CONNECT:-ok}" == "fail" ]]; then
      echo "failed to connect to $target"
      exit 1
    fi
    echo "connected to $target"
    exit 0
    ;;
  disconnect)
    target=${args[1]:-}
    # A failing target is the normal case here: adb returns non-zero for one it
    # has already dropped, which is exactly what the guards in stop.sh exist for.
    for bad in ${MOCK_ADB_DISCONNECT_FAIL:-}; do
      if [[ "$bad" == "$target" ]]; then
        echo "error: no such device '$target'"
        exit 1
      fi
    done
    echo "disconnected $target"
    exit 0
    ;;
  tcpip)
    # No case drives a tcpip failure: start.sh has no handling for one, and a
    # test that asserted a message there would be asserting behaviour the script
    # does not have.
    exit 0
    ;;
  shell)
    # `shell ip addr` is the only shell call either script makes.
    if [[ "${args[*]:-}" == "shell ip addr" ]]; then
      printf '%s\n' "${MOCK_ADB_SHELL_ADDR:-}"
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF

cat >"$TEST_DIR/bin/ping" <<'EOF'
#!/usr/bin/env bash
# MOCK_PING=fail makes every candidate unreachable.
# MOCK_PING_FAIL lists individual addresses that must not answer, which is what
# separates "the first candidate" from "the first reachable candidate".
addr=${*: -1}
if [[ "${MOCK_PING:-ok}" == "fail" ]]; then
  echo "ping: $addr: connect: Network is unreachable" >&2
  exit 1
fi
for bad in ${MOCK_PING_FAIL:-}; do
  if [[ "$bad" == "$addr" ]]; then
    echo "ping: $addr: connect: Network is unreachable" >&2
    exit 1
  fi
done
exit 0
EOF

cat >"$TEST_DIR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
# No-op sleep. start.sh sleeps 2s after tcpip and 3s between connect attempts;
# stubbing it keeps the suite in the seconds range. Every child is still wrapped
# in `timeout`, so a real sleep creeping back in shows up as a slow case rather
# than as a hung one.
#
# Recording the requested durations is what lets a case assert that the stub is
# the sleep that ran. A wall-clock bound cannot: the happy path only ever spends
# the 2s, which is inside the noise of a loaded machine, so "the suite was fast"
# is not evidence that anything was stubbed.
if [[ -n "${MOCK_SLEEP_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$MOCK_SLEEP_LOG"
fi
exit 0
EOF

chmod +x "$TEST_DIR/bin/adb" "$TEST_DIR/bin/ping" "$TEST_DIR/bin/sleep"

# --- fixtures ----------------------------------------------------------------

# A realistic `ip addr` from a phone: loopback and a cellular interface that
# must both be discarded, and the Wi-Fi address that must win.
IP_ADDR_FIXTURE="1: lo: <LOOPBACK> mtu 65536
    inet 127.0.0.1/8 scope host lo
2: rmnet_data0: <POINTOPOINT,MULTICAST> mtu 1500
    inet 10.132.19.5/23 scope global rmnet_data0
3: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 192.168.139.208/24 brd 192.168.139.255 scope global wlan0"

# Two addresses on one Wi-Fi interface, both pingable. Which one is chosen is
# only observable if BOTH are already in the device dump, otherwise a run that
# picked the second would fail the final verification for the wrong reason and
# the assertion would stop discriminating.
IP_ADDR_TWO_WIFI="3: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 192.168.139.208/24 brd 192.168.139.255 scope global wlan0
    inet 192.168.139.209/24 brd 192.168.139.255 scope global wlan0"

BOTH_WIFI_DEVICES="List of devices attached
422ae881               device usb:2-3
192.168.139.208:5555   device
192.168.139.209:5555   device"

# An unknown interface carrying a private address and no Wi-Fi at all. The `*)`
# arm of the interface filter is the only thing that can reject this one: it is
# neither a recognised Wi-Fi interface nor a recognised cellular one, so
# is_unreachable_ip decides. With nothing else left, a candidate that survives
# the filter becomes the target; one that does not leaves step_get_ip with no
# address at all.
IP_ADDR_PRIVATE_UNKNOWN="2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 10.8.0.5/24 brd 10.8.0.255 scope global eth0"

# One USB device already visible as a wireless target, so the post-tcpip
# verification can succeed.
USB_DEVICES="List of devices attached
422ae881               device usb:2-3
192.168.139.208:5555   device"

TWO_USB_DEVICES="List of devices attached
422ae881               device usb:1-2
8a1b2c3d               device usb:1-4
192.168.139.208:5555   device"

# Eight USB devices, so a zero-padded answer ("08") can be shown to select the
# eighth rather than dying on an invalid octal number.
EIGHT_USB_DEVICES="List of devices attached
usbdev01               device usb:1-1
usbdev02               device usb:1-2
usbdev03               device usb:1-3
usbdev04               device usb:1-4
usbdev05               device usb:1-5
usbdev06               device usb:1-6
usbdev07               device usb:1-7
usbdev08               device usb:1-8
192.168.139.208:5555   device"

NO_DEVICES="List of devices attached"

# The same USB setup with the post-tcpip wireless entry on a specific port, for
# the cases that pass a non-default --port: the final verification greps for
# "$DEVICE_IP:$PORT", so a fixture hardcoded to 5555 would fail a healthy run.
usb_devices_on() {
  printf 'List of devices attached\n422ae881               device usb:2-3\n192.168.139.208:%s   device\n' "$1"
}

WIRELESS_MIXED="List of devices attached
192.168.1.50:5555    offline
192.168.1.51:5555    no permissions (user in plugdev group); see [http://developer.android.com/tools/device.html]
422ae881               device usb:2-3"

# --- runner ------------------------------------------------------------------

# start.sh and stop.sh read their interactive prompts from /dev/tty. Redirecting
# stdin is not enough: if the suite is run from an interactive shell the child
# would inherit the real terminal and `read </dev/tty` would block. setsid puts
# each child in its own session with no controlling terminal, which is what
# makes the documented defaults apply deterministically. Every child is wrapped
# in `timeout` regardless, so without setsid a case fails instead of hanging.
NO_TTY=()
if command -v setsid >/dev/null 2>&1; then
  NO_TTY=(setsid -w)
else
  echo "NOTE: setsid not found; cases run without a controlling terminal of their own" >&2
fi

# A pty is the only way to feed a specific answer to a /dev/tty prompt.
# util-linux `script` is the cheapest way to get one; without it the
# answer-driven cases are skipped visibly rather than silently passing as the
# default-answer path, which would make them look like coverage.
PTY_AVAILABLE=false
if command -v script >/dev/null 2>&1; then
  PTY_AVAILABLE=true
fi

# run_script <start|stop> <tag> <devices> [args...] — one case in one call.
# MOCK_* for anything else come from the caller's environment and are pinned to
# a default here so a value set for one case cannot leak into the next.
run_script() {
  local script=$1 tag=$2 devices=$3
  shift 3
  rm -f "$TEST_DIR/calls-$tag.log" "$TEST_DIR/sleeps-$tag.log"
  env MOCK_ADB_DEVICES="$devices" \
    MOCK_ADB_SHELL_ADDR="${MOCK_ADB_SHELL_ADDR:-$IP_ADDR_FIXTURE}" \
    MOCK_ADB_PAIR="${MOCK_ADB_PAIR:-ok}" \
    MOCK_ADB_CONNECT="${MOCK_ADB_CONNECT:-ok}" \
    MOCK_ADB_KILL_SERVER="${MOCK_ADB_KILL_SERVER:-ok}" \
    MOCK_ADB_DISCONNECT_FAIL="${MOCK_ADB_DISCONNECT_FAIL:-}" \
    MOCK_PING="${MOCK_PING:-ok}" \
    MOCK_PING_FAIL="${MOCK_PING_FAIL:-}" \
    MOCK_ADB_CALL_LOG="$TEST_DIR/calls-$tag.log" \
    MOCK_SLEEP_LOG="$TEST_DIR/sleeps-$tag.log" \
    HOME="$TEST_DIR/home" \
    PATH="$TEST_DIR/bin:$BASE_PATH" \
    "${NO_TTY[@]}" timeout 10s bash "$ROOT_DIR/$script.sh" "$@" </dev/null 2>&1
}

# pty_start <tag> <devices> <stdin text> — the same thing for the cases that must
# answer a prompt. `script` supplies the pty, so the child does get a working
# /dev/tty and reads the piped text. Every value goes through printf %q because
# the device list is multi-line.
#
# The same eight knobs run_script pins are pinned here, and the environment is
# scrubbed at startup, so a knob's value can only be the one this case set with
# its prefix. Naming all of them matters independently of that: a knob missing
# from the list is simply not passed, so the child sees whatever the environment
# happened to hold.
#
# The command is passed to `script` unwrapped on purpose. A `bash -c '…'`
# wrapper (tried here to shave script's teardown) puts the managed command in a
# different process group, and start.sh's `read … </dev/tty` then takes SIGTTIN
# and hangs until `timeout` kills it — every pty case returned 124. Unwrapped,
# a pty case costs about half a second.
pty_start() {
  local tag=$1 devices=$2 answer=$3 cmd
  printf -v cmd 'env PATH=%q HOME=%q MOCK_ADB_DEVICES=%q MOCK_ADB_SHELL_ADDR=%q MOCK_ADB_PAIR=%q MOCK_ADB_CONNECT=%q MOCK_ADB_KILL_SERVER=%q MOCK_ADB_DISCONNECT_FAIL=%q MOCK_PING=%q MOCK_PING_FAIL=%q MOCK_ADB_CALL_LOG=%q MOCK_SLEEP_LOG=%q timeout 10s bash %q' \
    "$TEST_DIR/bin:$BASE_PATH" "$TEST_DIR/home" "$devices" \
    "${MOCK_ADB_SHELL_ADDR:-$IP_ADDR_FIXTURE}" \
    "${MOCK_ADB_PAIR:-ok}" "${MOCK_ADB_CONNECT:-ok}" \
    "${MOCK_ADB_KILL_SERVER:-ok}" "${MOCK_ADB_DISCONNECT_FAIL:-}" \
    "${MOCK_PING:-ok}" "${MOCK_PING_FAIL:-}" \
    "$TEST_DIR/calls-$tag.log" "$TEST_DIR/sleeps-$tag.log" "$ROOT_DIR/start.sh"
  rm -f "$TEST_DIR/calls-$tag.log" "$TEST_DIR/sleeps-$tag.log"
  printf '%s' "$answer" | script -qec "$cmd" /dev/null 2>&1
}

# How many recorded adb invocations contain a pattern. Prints 0 rather than
# failing when there is no match, so a caller can compare against a count.
call_count() {
  local tag=$1 pattern=$2 n
  n=$(grep -c -- "$pattern" "$TEST_DIR/calls-$tag.log" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

calls() {
  cat "$TEST_DIR/calls-$1.log" 2>/dev/null || true
}

# Every sleep the stub was asked for, one duration per line. Empty means the
# stub never ran, i.e. something real shadowed it.
sleeps() {
  cat "$TEST_DIR/sleeps-$1.log" 2>/dev/null || true
}

# Drop the temp tree. Registered as the EXIT trap so a failing assertion still
# cleans up. There is no pid sweep to do: every child in this suite is a
# foreground `timeout` in a command substitution, which reaps its own child
# before the harness ever sees its status, so a case that fails its assertions
# has nothing left running either way. A sweep over a glob nothing writes
# would only look like a guarantee.
cleanup() {
  rm -rf "$TEST_DIR"
  return 0
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  [[ $# -ge 2 ]] && echo "$2" >&2
  exit 1
}

# --- start.sh: argument handling ---------------------------------------------

output=$(run_script start help "" --help)
status=$?
[[ $status -eq 0 ]] || fail "start.sh --help exited $status; expected 0" "$output"
[[ "$output" == *"Usage: ./start.sh [options]"* ]] || fail "start.sh --help has no usage line" "$output"
for option in "-p, --port P" "-h, --help"; do
  [[ "$output" == *"$option"* ]] || fail "start.sh --help does not document $option" "$output"
done

output=$(run_script start badflag "" --bogus)
status=$?
[[ $status -eq 1 ]] || fail "an unknown flag exited $status; expected 1" "$output"
[[ "$output" == *"Unknown option: --bogus"* ]] || fail "the unknown flag is not named" "$output"
[[ "$output" == *"Usage: ./start.sh"* ]] || fail "an unknown flag did not show help" "$output"

# --port is validated before adb ever sees it. Non-numeric is one failure mode
# and out-of-range is the other, so both are rejected with the offending value
# named; a bare flag is a third, reported before the range check. The last
# value is 2^64 + 5555: bash arithmetic wraps, so it compares equal to 5555 and
# only the length test rejects it.
for bad_port in abc 80 1023 70000 99999 18446744073709557171; do
  output=$(run_script start "badport$bad_port" "$USB_DEVICES" --port "$bad_port")
  status=$?
  [[ $status -eq 1 ]] || fail "--port $bad_port exited $status; expected 1" "$output"
  [[ "$output" == *"Invalid port: $bad_port (must be a number between 1024 and 65535)"* ]] ||
    fail "--port $bad_port was not rejected with a message naming it" "$output"
  [[ "$(call_count "badport$bad_port" tcpip)" -eq 0 ]] ||
    fail "--port $bad_port still reached 'adb tcpip'" "$output"
done

for bare_port in "--port" "--port -1"; do
  output=$(run_script start "bare${bare_port// /x}" "$USB_DEVICES" $bare_port)
  status=$?
  [[ $status -eq 1 ]] || fail "a bare $bare_port exited $status; expected 1" "$output"
  [[ "$output" == *"requires a port argument"* ]] || fail "a bare $bare_port was not reported" "$output"
done

# A valid port reaches adb. Both ends of the accepted range are worth pinning:
# 1024 is the lower bound and 5555 the default.
for good_port in 1024 5555 37000 65535; do
  output=$(run_script start "goodport$good_port" "$(usb_devices_on "$good_port")" --port "$good_port")
  status=$?
  [[ $status -eq 0 ]] || fail "--port $good_port was rejected (status $status)" "$output"
  [[ "$output" == *"Switching device to TCP/IP mode on port $good_port"* ]] ||
    fail "--port $good_port was not used" "$output"
  [[ "$(call_count "goodport$good_port" "tcpip $good_port")" -eq 1 ]] ||
    fail "--port $good_port did not reach 'adb tcpip'" "$(calls "goodport$good_port")"
done

# --- start.sh: no USB device -------------------------------------------------

# The default answer at the pairing prompt is yes, so the only way to reach the
# declined branch is to answer no. That needs a pty.
if [[ $PTY_AVAILABLE == true ]]; then
  output=$(pty_start decline "$NO_DEVICES" 'n
')
  status=$?
  [[ $status -eq 1 ]] || fail "declining pairing exited $status; expected 1" "$output"
  [[ "$output" == *"No USB device detected"* ]] || fail "the missing USB device was not reported" "$output"
  [[ "$output" == *"Connect your phone via USB and re-run standard setup."* ]] ||
    fail "declining pairing gave no next step" "$output"
  [[ "$(call_count decline pair)" -eq 0 ]] || fail "declined pairing still ran 'adb pair'" "$(calls decline)"
  [[ "$(call_count decline connect)" -eq 0 ]] || fail "declined pairing still ran 'adb connect'" "$(calls decline)"

  # The Android 11+ path end to end: pair, keep the default connect port,
  # connect, and finish.
  output=$(pty_start pairok "$NO_DEVICES" 'y
192.168.1.50:37123
123456

')
  status=$?
  [[ $status -eq 0 ]] || fail "a successful pairing run exited $status; expected 0" "$output"
  [[ "$output" == *"Android 11+ Wireless Pairing Mode"* ]] || fail "the pairing mode was not announced" "$output"
  [[ "$output" == *"Pairing successful!"* ]] || fail "a successful pair was not confirmed" "$output"
  [[ "$(calls pairok)" == *"pair 192.168.1.50:37123 123456"* ]] ||
    fail "adb pair was not called with the entered address and code" "$(calls pairok)"
  # An empty answer at the port prompt must keep the default, not blank the port.
  [[ "$(calls pairok)" == *"connect 192.168.1.50:5555"* ]] ||
    fail "an empty port answer did not keep the default 5555" "$(calls pairok)"
  [[ "$output" == *"Done! Enjoy wireless ADB."* ]] || fail "the pairing path did not complete" "$output"

  # The port prompt is the second way of setting PORT, so it gets the same check
  # as --port. Feeding junk here is what proves the two paths share _valid_port.
  output=$(pty_start pairbadport "$NO_DEVICES" 'y
192.168.1.50:37123
123456
abc
')
  status=$?
  [[ $status -eq 1 ]] || fail "an invalid port at the pairing prompt exited $status; expected 1" "$output"
  [[ "$output" == *"Invalid port: abc (must be a number between 1024 and 65535)"* ]] ||
    fail "the pairing prompt did not reject a non-numeric port" "$output"
  [[ "$(call_count pairbadport connect)" -eq 0 ]] ||
    fail "an invalid port still reached 'adb connect'" "$(calls pairbadport)"

  # A valid custom port at the prompt is honored.
  output=$(pty_start paircustomport "$NO_DEVICES" 'y
192.168.1.50:37123
123456
37000
')
  status=$?
  [[ $status -eq 0 ]] || fail "a custom port at the pairing prompt exited $status; expected 0" "$output"
  [[ "$(calls paircustomport)" == *"connect 192.168.1.50:37000"* ]] ||
    fail "the custom port from the pairing prompt did not reach adb" "$(calls paircustomport)"

  # The picker reads /dev/tty, so a specific answer needs a pty too.
  # P5: garbage input must land on the FIRST device. Unvalidated input used to
  # resolve to the LAST one, which silently connected the wrong phone.
  output=$(pty_start pickgarbage "$TWO_USB_DEVICES" 'abc
')
  status=$?
  [[ $status -eq 0 ]] || fail "garbage picker input killed start.sh (status $status)" "$output"
  [[ "$output" == *"Select device number [1-2, default: 1]"* ]] ||
    fail "the picker prompt does not advertise its default" "$output"
  [[ "$output" == *"Selected device: 422ae881"* ]] ||
    fail "garbage picker input did not fall back to the first device" "$output"
  [[ "$(calls pickgarbage)" == *" 422ae881 tcpip 5555"* ]] ||
    fail "the first device was not the one put into tcpip mode" "$(calls pickgarbage)"
  [[ "$(calls pickgarbage)" != *" 8a1b2c3d "* ]] ||
    fail "the picker resolved garbage input to the last device" "$(calls pickgarbage)"

  # P6: a number past the end of the list is out of range, not an empty
  # serial — the other way the same guard can fail.
  output=$(pty_start pickrange "$TWO_USB_DEVICES" '9
')
  status=$?
  [[ $status -eq 0 ]] || fail "an out-of-range picker choice killed start.sh (status $status)" "$output"
  [[ "$output" == *"Selected device: 422ae881"* ]] ||
    fail "an out-of-range choice did not fall back to the first device" "$output"
  [[ "$(calls pickrange)" != *" 8a1b2c3d "* ]] ||
    fail "an out-of-range choice reached the wrong device" "$(calls pickrange)"

  # P7: a zero-padded answer must not be read as an invalid octal number, which
  # is what killed the picker before the input was normalized.
  output=$(pty_start pickzero "$EIGHT_USB_DEVICES" '08
')
  status=$?
  [[ $status -eq 0 ]] || fail "a zero-padded device choice killed start.sh (status $status)" "$output"
  [[ "$output" == *"Selected device: usbdev08"* ]] ||
    fail "device choice 08 did not select the eighth device" "$output"
  [[ "$output" != *"value too great for base"* ]] ||
    fail "device choice 08 was read as an octal number" "$output"
else
  echo "SKIP: answer-driven start.sh cases (pairing decline, pairing success, prompt port, device picker) need util-linux 'script' for a pty"
fi

# --- start.sh: USB happy path ------------------------------------------------

# The mock ping answers immediately, so the Wi-Fi address from the ip addr
# fixture must be selected on the first candidate.
output=$(run_script start usb "$USB_DEVICES")
status=$?
[[ $status -eq 0 ]] || fail "the USB happy path exited $status; expected 0" "$output"
[[ "$output" == *"USB device detected: 422ae881"* ]] || fail "the USB device was not detected" "$output"
[[ "$output" == *"Target IP address: 192.168.139.208"* ]] ||
  fail "the Wi-Fi address was not selected" "$output"
[[ "$output" == *"TCP/IP mode enabled"* ]] || fail "tcpip mode was not reported" "$output"
[[ "$output" == *"Connecting to 192.168.139.208:5555"* ]] || fail "the connect step named the wrong target" "$output"
[[ "$output" == *"connected to 192.168.139.208:5555"* ]] || fail "a successful connect was not reported" "$output"
[[ "$output" == *"Connected wirelessly!"* ]] || fail "the wireless verification did not pass" "$output"
[[ "$output" == *"Done! Enjoy wireless ADB."* ]] || fail "the happy path did not complete" "$output"
# Loopback and the cellular address must never be chosen, even though both are
# present in the fixture.
[[ "$output" != *"Target IP address: 127.0.0.1"* && "$output" != *"Target IP address: 10.132.19.5"* ]] ||
  fail "an unreachable interface was chosen" "$output"
# The stub sleep, not a real one, is what ran: it was asked for the 2s settle
# after tcpip and got it. A wall-clock bound cannot establish this — the happy
# path only ever spends the 2s, which is inside the noise of a loaded machine.
[[ "$(sleeps usb)" == "2" ]] ||
  fail "the tcpip settle did not go through the stub sleep" "$(sleeps usb)"

# ICMP can be blocked, so a Wi-Fi address that does not answer must still be
# tried, with a warning, rather than dropping the user at a manual-IP prompt.
output=$(MOCK_PING=fail run_script start noping "$USB_DEVICES")
status=$?
[[ $status -eq 0 ]] || fail "an unpingable Wi-Fi address exited $status; expected 0" "$output"
[[ "$output" == *"Could not ping 192.168.139.208, but it is on a Wi-Fi interface; trying it anyway."* ]] ||
  fail "the unreachable-Wi-Fi fallback did not warn" "$output"
[[ "$output" == *"Done! Enjoy wireless ADB."* ]] || fail "the fallback did not connect" "$output"

# --- start.sh: IP selection ---------------------------------------------------

# Two pingable addresses on one Wi-Fi interface: the first candidate wins. Both
# are already in the device dump, so a run that picked the second would still
# exit 0 — the assertion on the chosen address is the only thing that
# discriminates, which is what makes it worth having.
output=$(MOCK_ADB_SHELL_ADDR="$IP_ADDR_TWO_WIFI" run_script start pingfirst "$BOTH_WIFI_DEVICES")
status=$?
[[ $status -eq 0 ]] || fail "two pingable candidates returned $status; expected 0" "$output"
[[ "$output" == *"Target IP address: 192.168.139.208"* ]] ||
  fail "the first pingable candidate was not chosen" "$output"
[[ "$(calls pingfirst)" == *"connect 192.168.139.208:5555"* ]] ||
  fail "the first candidate is not the one connected to" "$(calls pingfirst)"

# The first candidate does not answer, the second does: the selection is the
# first REACHABLE candidate, not simply the first one. This is the case that
# pins the ping loop itself — with the loop deleted, step_get_ip falls back to
# the first Wi-Fi address regardless of reachability, which is 192.168.139.208,
# and the assertion below fails.
output=$(MOCK_PING_FAIL=192.168.139.208 \
  MOCK_ADB_SHELL_ADDR="$IP_ADDR_TWO_WIFI" run_script start pingsecond "$BOTH_WIFI_DEVICES")
status=$?
[[ $status -eq 0 ]] || fail "one unreachable candidate returned $status; expected 0" "$output"
[[ "$output" == *"Target IP address: 192.168.139.209"* ]] ||
  fail "the unreachable first candidate was chosen over the reachable second one" "$output"
[[ "$output" != *"Could not ping"* ]] ||
  fail "a reachable second candidate still produced the fallback warning" "$output"
[[ "$(calls pingsecond)" == *"connect 192.168.139.209:5555"* ]] ||
  fail "the reachable second candidate is not the one connected to" "$(calls pingsecond)"

# An unknown interface on a private range is not a reachable LAN address. With
# no Wi-Fi candidate to fall back on, the run must end at the manual-IP prompt
# with no address — a candidate that survived the filter here would be chosen
# and the run would succeed.
output=$(MOCK_ADB_SHELL_ADDR="$IP_ADDR_PRIVATE_UNKNOWN" \
  run_script start privateunknown "$USB_DEVICES")
status=$?
[[ $status -eq 1 ]] || fail "a private address on an unknown interface exited $status; expected 1" "$output"
[[ "$output" != *"Target IP address: 10.8.0.5"* ]] ||
  fail "a private address on an unknown interface was treated as reachable" "$output"
[[ "$output" == *"No IP provided. Exiting."* ]] ||
  fail "no reachable address did not end at the manual-IP prompt" "$output"
[[ "$(call_count privateunknown tcpip)" -eq 0 ]] ||
  fail "an unreachable address still reached 'adb tcpip'" "$(calls privateunknown)"

# The post-tcpip verification matches the target literally. The dump below holds
# only a lookalike serial, one non-digit character for each '.' in
# 192.168.1.5 and the same length, so a regex match would call that a successful
# wireless connection and end the run with a success message for a phone that
# was never reached.
output=$(MOCK_ADB_SHELL_ADDR="3: wlan0: <BROADCAST> mtu 1500
    inet 192.168.1.5/24 brd 192.168.1.255 scope global wlan0" \
  run_script start lookalike "List of devices attached
422ae881               device usb:2-3
192x168x1y5:5555        device")
status=$?
[[ $status -eq 1 ]] || fail "a lookalike serial passed the wireless verification (status $status)" "$output"
[[ "$output" == *"Device not showing as connected wirelessly. Check the IP and try again."* ]] ||
  fail "the lookalike serial was accepted as the connected device" "$output"
[[ "$output" != *"✓ Connected wirelessly!"* ]] ||
  fail "the lookalike serial was reported as a wireless connection" "$output"
[[ "$(calls lookalike)" == *"connect 192.168.1.5:5555"* ]] ||
  fail "the lookalike case did not connect to the real target" "$(calls lookalike)"
[[ "$output" != *"Done! Enjoy wireless ADB."* ]] || fail "a failed verification still reported success" "$output"

# --- start.sh: connect failure ------------------------------------------------

# The retry must be visible, both attempts must actually be made, and the second
# failure must end with an actionable message and exit 1. Before Task 4 the
# script died silently right after the "Retrying" line.
output=$(MOCK_ADB_CONNECT=fail run_script start connectfail "$USB_DEVICES")
status=$?
[[ $status -eq 1 ]] || fail "a double connect failure exited $status; expected 1" "$output"
[[ "$output" == *"Connection failed. Retrying in 3 seconds..."* ]] ||
  fail "the retry was not announced" "$output"
[[ "$output" == *"Could not connect to 192.168.139.208:5555 after 2 attempts."* ]] ||
  fail "the failure message does not name the target" "$output"
[[ "$output" == *"adb kill-server && adb start-server"* ]] ||
  fail "the failure message gives no next step" "$output"
[[ "$output" != *"Done! Enjoy wireless ADB."* ]] ||
  fail "a failed connect still reported success" "$output"
[[ "$(call_count connectfail connect)" -eq 2 ]] ||
  fail "connect was attempted $(call_count connectfail connect) times; expected 2" "$(calls connectfail)"
# Both waits the retry path takes — the 2s settle and the 3s between attempts —
# went through the stub, so the retry is real and cost nothing.
[[ "$(sleeps connectfail)" == $'2\n3' ]] ||
  fail "the connect retry did not sleep 2 then 3 through the stub" "$(sleeps connectfail)"

# A pairing path that cannot connect fails the same way, and must not report
# success either.
if [[ $PTY_AVAILABLE == true ]]; then
  output=$(MOCK_ADB_CONNECT=fail pty_start pairconnectfail "$NO_DEVICES" 'y
192.168.1.50:37123
123456

')
  status=$?
  [[ $status -eq 1 ]] || fail "a failed pairing connect exited $status; expected 1" "$output"
  [[ "$output" == *"Could not connect to 192.168.1.50:5555 after 2 attempts."* ]] ||
    fail "the pairing failure does not name its target" "$output"
  [[ "$(call_count pairconnectfail connect)" -eq 2 ]] ||
    fail "the pairing path made $(call_count pairconnectfail connect) connect attempts; expected 2" \
      "$(calls pairconnectfail)"
else
  echo "SKIP: pairing connect-failure case needs util-linux 'script' for a pty"
fi

# A refused pairing is reported, not ignored.
if [[ $PTY_AVAILABLE == true ]]; then
  output=$(MOCK_ADB_PAIR=fail pty_start pairfail "$NO_DEVICES" 'y
192.168.1.50:37123
000000
')
  status=$?
  [[ $status -eq 1 ]] || fail "a failed pair exited $status; expected 1" "$output"
  [[ "$output" == *"Pairing failed. Check the IP, pairing port and code, then try again."* ]] ||
    fail "a failed pair gave no next step" "$output"
  [[ "$(call_count pairfail connect)" -eq 0 ]] || fail "a failed pair still tried to connect" "$(calls pairfail)"
else
  echo "SKIP: pairing failure case needs util-linux 'script' for a pty"
fi

# --- start.sh / stop.sh: adb missing ------------------------------------------

# A PATH with no adb on it. Only the tools a script can reach before check_adb
# exits are linked in, rather than a mirror of /usr/bin: a full mirror costs
# about ten seconds of symlinks, and check_adb is the first thing either script
# does after the banner.
#
# bash and timeout are the two this cannot do without — one runs the script, the
# other bounds it. setsid is not required: without it the runner simply passes no
# argument, which the "NOTE: setsid not found" path already covers. Anything
# missing is reported by name and the cases are skipped, because the failure
# mode otherwise is a bare status 127 that looks like a broken assertion.
NO_ADB_TOOLS=(bash env timeout awk grep sed cat head tail tr cut sort uname id whoami sleep setsid)
NO_ADB_REQUIRED=(bash timeout)
NO_ADB_BIN="$TEST_DIR/no-adb-bin"
mkdir -p "$NO_ADB_BIN"
for tool in "${NO_ADB_TOOLS[@]}"; do
  tool_path=$(command -v "$tool" 2>/dev/null) || continue
  ln -sf "$tool_path" "$NO_ADB_BIN/$tool" 2>/dev/null || true
done
NO_ADB_OK=true
for tool in "${NO_ADB_REQUIRED[@]}"; do
  if [[ ! -x "$NO_ADB_BIN/$tool" ]]; then
    NO_ADB_OK=false
    echo "SKIP: no-adb cases need '$tool' on this system to build a PATH without adb" >&2
  fi
done

if [[ $NO_ADB_OK == true ]]; then
  out=$(env -i HOME="$TEST_DIR/home" PATH="$NO_ADB_BIN" \
    "${NO_TTY[@]}" timeout 10s bash "$ROOT_DIR/start.sh" </dev/null 2>&1)
  status=$?
  [[ $status -eq 1 ]] || fail "start.sh without adb exited $status; expected 1" "$out"
  [[ "$out" == *"adb not found on this system."* ]] || fail "start.sh did not report the missing adb" "$out"
  # Install hints must use pkexec, never sudo.
  [[ "$out" == *"pkexec apt install adb"* ]] || fail "start.sh has no pkexec install hint" "$out"
  [[ "$out" != *"sudo"* ]] || fail "start.sh suggests sudo" "$out"
else
  echo "SKIP: start.sh missing-adb case (no bash/timeout to build a PATH without adb)"
fi

# --- stop.sh -----------------------------------------------------------------

output=$(run_script stop help "" --help)
status=$?
[[ $status -eq 0 ]] || fail "stop.sh --help exited $status; expected 0" "$output"
[[ "$output" == *"Usage: ./stop.sh [options]"* ]] || fail "stop.sh --help has no usage line" "$output"
for option in "-a, --all" "-k, --kill" "-h, --help"; do
  [[ "$output" == *"$option"* ]] || fail "stop.sh --help does not document $option" "$output"
done

output=$(run_script stop badflag "" --bogus)
status=$?
[[ $status -eq 1 ]] || fail "stop.sh accepted an unknown flag (status $status)" "$output"
[[ "$output" == *"Unknown option: --bogus"* ]] || fail "stop.sh does not name the unknown flag" "$output"
[[ "$(call_count badflag devices)" -eq 0 ]] ||
  fail "stop.sh listed devices before rejecting an unknown flag" "$(calls badflag)"

# No wireless targets: report it, then take the default action. The default is
# "2) Exit", and the branch must not spend a second adb call re-listing devices.
output=$(run_script stop nowireless "List of devices attached
422ae881               device usb:2-3")
status=$?
[[ $status -eq 0 ]] || fail "stop.sh with no wireless targets exited $status; expected 0" "$output"
[[ "$output" == *"No active wireless ADB connections found."* ]] ||
  fail "stop.sh did not report the empty wireless list" "$output"
[[ "$output" == *"Exiting."* ]] || fail "the default action was not taken" "$output"
[[ "$(call_count nowireless devices)" -eq 1 ]] ||
  fail "stop.sh called 'adb devices' $(call_count nowireless devices) times; expected 1" "$(calls nowireless)"

# -a disconnects every wireless target and leaves the server alone.
output=$(run_script stop all "$WIRELESS_MIXED" -a)
status=$?
[[ $status -eq 0 ]] || fail "stop.sh -a exited $status; expected 0" "$output"
[[ "$output" == *"All wireless ADB connections disconnected."* ]] ||
  fail "stop.sh -a did not report success" "$output"
[[ "$(calls all)" == *"disconnect 192.168.1.50:5555"* ]] ||
  fail "the offline target was not disconnected" "$(calls all)"
[[ "$(calls all)" == *"disconnect 192.168.1.51:5555"* ]] ||
  fail "the no-permissions target was not disconnected" "$(calls all)"
# The call log, not the output: stop.sh prints "[*] Disconnecting <serial>…"
# with a capital D, so grepping the output for a lowercase "disconnect <serial>"
# would never match and the assertion would pass whatever adb was asked to do.
[[ "$(call_count all "disconnect 422ae881")" -eq 0 ]] ||
  fail "a USB target was sent to adb disconnect" "$(calls all)"
[[ "$(call_count all disconnect)" -eq 2 ]] ||
  fail "stop.sh -a made $(call_count all disconnect) disconnect calls; expected 2" "$(calls all)"
[[ "$(call_count all kill-server)" -eq 0 ]] || fail "stop.sh -a killed the server" "$(calls all)"

# Each target is labelled with its real state, and the whole remainder of the
# status line is used so the plugdev message renders instead of "(no)".
output=$(run_script stop labels "$WIRELESS_MIXED")
status=$?
[[ $status -eq 0 ]] || fail "the labelling run exited $status; expected 0" "$output"
[[ "$output" == *"• 192.168.1.50:5555 (offline)"* ]] ||
  fail "the offline target is not labelled offline" "$output"
[[ "$output" == *"• 192.168.1.51:5555 (no permissions (user in plugdev group); see [http://developer.android.com/tools/device.html])"* ]] ||
  fail "the no-permissions status was truncated" "$output"
[[ "$output" != *"422ae881"* ]] || fail "a USB device was listed as a wireless target" "$output"
[[ "$output" != *"• 192.168.1.50:5555 (device)"* ]] ||
  fail "an offline target is labelled as an active connection" "$output"
# One snapshot feeds both the list and the labels, so the two can never disagree.
[[ "$(call_count labels devices)" -eq 1 ]] ||
  fail "stop.sh called 'adb devices' $(call_count labels devices) times; expected 1" "$(calls labels)"

# The default action at the menu is "3) Cancel", which must touch nothing. The
# call log is the only place that can prove "nothing": the menu prompt and the
# Cancelled line are printed either way, so an output-only check passes even if
# the targets were disconnected just before the prompt.
output=$(run_script stop cancel "List of devices attached
192.168.1.50:5555    device")
status=$?
[[ $status -eq 0 ]] || fail "the cancel path exited $status; expected 0" "$output"
[[ "$output" == *"Cancelled."* ]] || fail "the cancel path did not report cancelling" "$output"
[[ "$(call_count cancel disconnect)" -eq 0 ]] ||
  fail "the cancel path still disconnected a target" "$(calls cancel)"
[[ "$(call_count cancel kill-server)" -eq 0 ]] || fail "the cancel path still killed the server" "$(calls cancel)"
[[ "$(call_count cancel start-server)" -eq 0 ]] || fail "the cancel path still restarted the server" "$(calls cancel)"

# -k validates adb in main, then kills the server without listing devices.
output=$(run_script stop kill "$WIRELESS_MIXED" -k)
status=$?
[[ $status -eq 0 ]] || fail "stop.sh -k exited $status; expected 0" "$output"
[[ "$output" == *"Killing ADB server..."* ]] || fail "stop.sh -k did not announce the kill" "$output"
[[ "$output" == *"ADB server killed."* ]] || fail "stop.sh -k did not report success" "$output"
[[ "$(call_count kill kill-server)" -eq 1 ]] || fail "adb kill-server was not called once" "$(calls kill)"
[[ "$(call_count kill devices)" -eq 0 ]] || fail "stop.sh -k listed devices" "$(calls kill)"

# A kill-server that fails is reported, with a next step, and is not fatal to
# the rest of the script's contract: exit 1 rather than a silent success.
output=$(MOCK_ADB_KILL_SERVER=fail run_script stop kilfail "$WIRELESS_MIXED" -k)
status=$?
[[ $status -eq 1 ]] || fail "a failed kill-server exited $status; expected 1" "$output"
[[ "$output" == *"adb kill-server failed. Try 'adb kill-server' manually."* ]] ||
  fail "a failed kill-server gave no next step" "$output"
[[ "$output" != *"ADB server killed."* ]] ||
  fail "a failed kill-server reported success" "$output"

# A disconnect that adb rejects must not abandon the targets after it, and must
# not claim success. The success line is the load-bearing part: a partial
# cleanup reported as complete is how a user loses track of a live target.
output=$(MOCK_ADB_DISCONNECT_FAIL="192.168.1.50:5555" run_script stop partial "$WIRELESS_MIXED" -a)
status=$?
[[ $status -eq 1 ]] || fail "a partial disconnect exited $status; expected 1" "$output"
[[ "$(calls partial)" == *"disconnect 192.168.1.50:5555"* ]] ||
  fail "the failing target was not attempted" "$(calls partial)"
[[ "$(calls partial)" == *"disconnect 192.168.1.51:5555"* ]] ||
  fail "the target after the failure was abandoned" "$(calls partial)"
[[ "$output" == *"Could not disconnect 1 of 2 target(s):"* ]] ||
  fail "the aggregate failure count is wrong" "$output"
[[ "$output" == *"• 192.168.1.50:5555"* ]] || fail "the failing target is not named" "$output"
[[ "$output" != *"All wireless ADB connections disconnected."* ]] ||
  fail "a partial disconnect still claimed success" "$output"
[[ "$output" == *"adb kill-server && adb start-server"* ]] ||
  fail "the partial failure gives no next step" "$output"

if [[ $NO_ADB_OK == true ]]; then
  # stop.sh's adb hint is the one Task 1 added hints to, so it needs coverage.
  out=$(env -i HOME="$TEST_DIR/home" PATH="$NO_ADB_BIN" \
    "${NO_TTY[@]}" timeout 10s bash "$ROOT_DIR/stop.sh" -a </dev/null 2>&1)
  status=$?
  [[ $status -eq 1 ]] || fail "stop.sh without adb exited $status; expected 1" "$out"
  [[ "$out" == *"adb not found on this system."* ]] || fail "stop.sh did not report the missing adb" "$out"
  [[ "$out" == *"pkexec pacman -S android-tools"* ]] || fail "stop.sh has no pkexec install hint" "$out"
  [[ "$out" != *"sudo"* ]] || fail "stop.sh suggests sudo" "$out"

  # adb is validated in one place, so -k is validated too. It used to run
  # check_adb from inside the argument-parsing loop, which is how -k came to
  # validate adb at a different point from every other path.
  out=$(env -i HOME="$TEST_DIR/home" PATH="$NO_ADB_BIN" \
    "${NO_TTY[@]}" timeout 10s bash "$ROOT_DIR/stop.sh" -k </dev/null 2>&1)
  status=$?
  [[ $status -eq 1 ]] || fail "stop.sh -k without adb exited $status; expected 1" "$out"
  [[ "$out" == *"adb not found on this system."* ]] ||
    fail "stop.sh -k did not validate adb" "$out"
  [[ "$out" != *"Killing ADB server..."* ]] || fail "stop.sh -k tried to kill a server with no adb" "$out"
else
  echo "SKIP: stop.sh missing-adb cases (no bash/timeout to build a PATH without adb)"
fi

echo "PASS: start.sh validates --port at both input paths, rejects unknown flags, and drives the Android 11+ pairing flow"
echo "PASS: start.sh falls back to the first device on bad picker input, completes the USB happy path, and reports a failed connect"
echo "PASS: start.sh picks the first reachable Wi-Fi address and rejects a private one on an unknown interface"
echo "PASS: stop.sh rejects unknown flags, labels each target with its real state, and lists devices exactly once"
echo "PASS: stop.sh -a disconnects every target, -k kills the server, a partial disconnect is not reported as success, and cancel touches nothing"
