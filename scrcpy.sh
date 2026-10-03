#!/usr/bin/env bash
set -eu

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Bash arithmetic reads a leading zero as an octal digit, so a device-picker
# answer of 08 aborts with "value too great for base", and sleep is handed a
# padded value. Strip the zero padding in one place for every user-supplied
# number: a whole number for the picker, optionally fractional for --timeout.
# A value with no numeric form is passed through untouched so the caller's own
# validation stays in charge. Defined above the flag parser because --timeout
# normalizes its value while parsing.
#
# Cross-reference: start.sh carries its own copy of this helper, because the
# three scripts are deliberately standalone (no shared library, no sourcing).
# The two differ on purpose, so do not "unify" them without reading both: every
# user-supplied number in start.sh is a whole number (a menu answer, a TCP
# port), so its copy drops the fractional branch, while --timeout here needs
# `0.5` to survive. This copy is the superset; start.sh's is the restriction.
_normalize_number() {
  local value=$1 int
  [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { printf '%s\n' "$value"; return 0; }
  int="${value%%.*}"
  # Keep at least one digit so 0.5 normalizes to 0.5 and not to .5.
  while [[ ${#int} -gt 1 && "${int:0:1}" == "0" ]]; do
    int="${int:1}"
  done
  if [[ "$value" == *.* ]]; then
    printf '%s.%s\n' "$int" "${value#*.}"
  else
    printf '%s\n' "$int"
  fi
}

SCRCPY_ARGS=()

show_help() {
  echo -e "${CYAN}ADB Wireless Connect - scrcpy.sh${NC}"
  echo ""
  echo "Usage: ./scrcpy.sh [options]"
  echo ""
  echo "Launch scrcpy for screen mirroring with custom resolution and FPS options."
  echo "Works with any connected device: USB (e.g. 422ae881) or wireless (e.g. 192.168.1.50:5555)."
  echo ""
  echo "Options:"
  echo "  -a, --args ...      Pass custom arguments to scrcpy (must be final option)"
  echo "  -s, --serial S      Specify device serial (USB id or ip:port)"
  echo "  -t, --timeout S     Startup grace period in seconds (default: $SCRCPY_TIMEOUT_DEFAULT)"
  echo "  -w, --wait          Run in the foreground and exit with scrcpy's status"
  echo "  -f, --force         Kill a scrcpy session already running, then start a new one"
  echo "  -h, --help          Show this help message"
  echo ""
  echo "Session notes:"
  echo "  Without --wait the launcher backgrounds scrcpy, waits $SCRCPY_TIMEOUT seconds to"
  echo "  confirm it survived startup, prints the log and PID file paths, and exits 0."
  echo "  That grace period defaults to $SCRCPY_TIMEOUT_DEFAULT seconds; --timeout S replaces it,"
  echo "  so a --help printed after --timeout N reports N in the sentence above."
  echo "  With --wait it blocks until scrcpy exits and exits with scrcpy's own status,"
  echo "  so a mid-session crash is visible in your terminal."
  echo ""
}

# Parse CLI flags
DEVICE_SERIAL=""
# The default is named once and read everywhere it is quoted, so the option list,
# the two --timeout rejection messages, and the session notes cannot drift apart.
SCRCPY_TIMEOUT_DEFAULT=2
SCRCPY_TIMEOUT=$SCRCPY_TIMEOUT_DEFAULT
SCRCPY_WAIT=0
SCRCPY_FORCE=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -a|--args)
      shift
      if [[ "$#" -eq 0 ]]; then
        echo -e "${YELLOW}[!] Option --args requires at least one argument.${NC}"
        show_help
        exit 1
      fi
      # --args takes the rest of the command line verbatim, so a second -a can
      # only turn up inside that first batch, where it would be forwarded to
      # scrcpy as an unknown option; -s/--serial inside a batch can no longer be
      # read as a script option at all. Both are rejected here.
      for _a in "$@"; do
        case "$_a" in
          -s|--serial)
            echo -e "${YELLOW}[!] -s/--serial must come before -a/--args.${NC}"
            show_help
            exit 1
            ;;
          -a|--args)
            echo -e "${YELLOW}[!] Option -a/--args may only be given once; everything after it is already forwarded to scrcpy as arguments.${NC}"
            show_help
            exit 1
            ;;
        esac
      done
      SCRCPY_ARGS=("$@")
      shift "$#"
      ;;
    -s|--serial)
      if [[ -z "${2:-}" || "${2:-}" =~ ^- ]]; then
        echo -e "${YELLOW}[!] Option $1 requires a device serial.${NC}"
        show_help
        exit 1
      fi
      DEVICE_SERIAL="$2"
      shift 2
      ;;
    -t|--timeout)
      if [[ -z "${2:-}" ]]; then
        echo -e "${YELLOW}[!] Option $1 requires a grace period in seconds, e.g. --timeout 2.${NC}"
        show_help
        exit 1
      fi
      # The format check also catches negatives and leading '-' values such as
      # "--timeout -s foo", so the message names the offending value.
      if ! [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo -e "${YELLOW}[!] --timeout must be a positive number of seconds, got: $2${NC}"
        echo "  Use a plain value such as 2 or 0.5; the default is $SCRCPY_TIMEOUT_DEFAULT."
        show_help
        exit 1
      fi
      # A value like 0 or 0.00 passes the format check but means "no grace
      # period at all", which would race a healthy slow start; reject it.
      if ! [[ "$2" =~ [1-9] ]]; then
        echo -e "${YELLOW}[!] --timeout must be greater than zero, got: $2${NC}"
        echo "  Use a positive value such as 2 or 0.5; the default is $SCRCPY_TIMEOUT_DEFAULT."
        show_help
        exit 1
      fi
      SCRCPY_TIMEOUT=$(_normalize_number "$2")
      shift 2
      ;;
    -w|--wait) SCRCPY_WAIT=1; shift ;;
    -f|--force) SCRCPY_FORCE=1; shift ;;
    -h|--help) show_help; exit 0 ;;
    *) echo -e "${YELLOW}[!] Unknown option: $1${NC}"; show_help; exit 1 ;;
  esac
done

print_banner() {
  echo ""
  echo -e "${CYAN}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║          scrcpy Launcher Script              ║"
  echo "  ║     Screen mirroring with custom options     ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

check_scrcpy() {
  if ! command -v scrcpy &>/dev/null; then
    echo -e "${YELLOW}[!] scrcpy not found on this system.${NC}"
    echo ""
    echo "  Install scrcpy:"
    echo "    pkexec apt install scrcpy           # Debian/Ubuntu/Pop!_OS"
    echo "    pkexec dnf install scrcpy           # Fedora"
    echo "    pkexec pacman -S scrcpy             # Arch"
    echo ""
    echo -e "${YELLOW}  After installing, re-run this script.${NC}"
    exit 1
  fi
  # A failed probe only means the version is unknown, not that scrcpy is
  # unusable, so warn and let launch_scrcpy report any real failure.
  local probe version
  probe=$(scrcpy --version 2>/dev/null) || probe=""
  # Real scrcpy reports "scrcpy 4.1 <https://github.com/Genymobile/scrcpy>";
  # only the version field belongs on the success line.
  version="${probe%%$'\n'*}"
  version="${version#scrcpy }"
  version="${version%%[[:space:]]*}"

  if [[ -n "$version" ]]; then
    echo -e "${GREEN}[✓] scrcpy detected (version ${version})${NC}"
  else
    echo -e "${YELLOW}[!] Could not determine the scrcpy version; continuing anyway.${NC}"
    echo "  Run 'scrcpy --version' yourself to check the install."
    echo -e "${GREEN}[✓] scrcpy detected${NC}"
  fi
}

check_adb() {
  if ! command -v adb &>/dev/null; then
    echo -e "${YELLOW}[!] adb not found on this system.${NC}"
    echo ""
    echo "  Install Android platform tools:"
    echo "    pkexec apt install adb              # Debian/Ubuntu/Pop!_OS"
    echo "    pkexec dnf install android-tools    # Fedora"
    echo "    pkexec pacman -S android-tools      # Arch"
    echo ""
    echo -e "${YELLOW}  After installing, re-run this script.${NC}"
    exit 1
  fi
  echo -e "${GREEN}[✓] adb detected${NC}"
}

_connected_devices() {
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}'
}

# Devices adb knows about but that are not usable yet: unauthorized, offline, etc.
_pending_devices() {
  adb devices 2>/dev/null | awk 'NR>1 && $2!="device" && NF>=2 {print $1" ("$2")"}'
}

# Wireless serials are host:port, emulators use the emulator-NNNN convention,
# everything else is a USB device id.
_device_kind() {
  if [[ "$1" =~ :[0-9]+$ ]]; then
    echo "wireless"
  elif [[ "$1" == emulator-* ]]; then
    echo "emulator"
  else
    echo "usb"
  fi
}

# Wireless devices first so the default pick stays wireless when both are present.
_sorted_devices() {
  local d
  while read -r d; do
    [[ -n "$d" ]] || continue
    echo "$(_device_kind "$d") $d"
  done < <(_connected_devices) | sort -k1,1r -k2,2
}

detect_device() {
  if [[ -n "$DEVICE_SERIAL" ]]; then
    if ! _connected_devices | grep -Fxq -- "$DEVICE_SERIAL"; then
      echo -e "${YELLOW}[!] Specified device $DEVICE_SERIAL is not connected or not authorized.${NC}"
      echo ""
      echo "  Usable devices:"
      _sorted_devices | sed 's/^\([^ ]*\) \(.*\)$/    \2  [\1]/'
      _pending_devices | sed 's/^/    (pending) /'
      exit 1
    fi
    echo -e "${GREEN}[✓] Using specified device: $DEVICE_SERIAL ($(_device_kind "$DEVICE_SERIAL"))${NC}"
    return 0
  fi

  local rows
  mapfile -t rows < <(_sorted_devices)

  if [[ ${#rows[@]} -eq 0 ]]; then
    local pending
    mapfile -t pending < <(_pending_devices)

    if [[ ${#pending[@]} -gt 0 ]]; then
      echo -e "${YELLOW}[!] No usable ADB devices found, but adb sees:${NC}"
      for p in "${pending[@]}"; do
        echo "    $p"
      done
      echo ""
      if printf '%s\n' "${pending[@]}" | grep -q "unauthorized"; then
        echo "  Unlock the phone and accept the 'Allow USB debugging?' prompt."
        echo "  Tick 'Always allow from this computer' to avoid this again."
      elif printf '%s\n' "${pending[@]}" | grep -q "offline"; then
        echo "  Device is offline: replug the cable, or re-run 'adb kill-server && adb start-server'."
      else
        echo "  Device is not ready: replug the cable and re-run this script."
      fi
      echo ""
      exit 1
    fi

    echo -e "${YELLOW}[!] No connected ADB devices found (USB or wireless).${NC}"
    echo ""
    echo "  Connect a device first:"
    echo "    ./start.sh              # USB setup"
    echo "    adb pair <ip:port>      # Android 11+ wireless pairing"
    echo ""
    exit 1
  elif [[ ${#rows[@]} -eq 1 ]]; then
    DEVICE_SERIAL="${rows[0]#* }"
    echo -e "${GREEN}[✓] Device detected: $DEVICE_SERIAL (${rows[0]%% *})${NC}"
  else
    echo -e "${YELLOW}[*] Multiple devices detected:${NC}"
    for i in "${!rows[@]}"; do
      echo "    $((i+1))) ${rows[$i]#* }  [${rows[$i]%% *}]"
    done
    read -rp "  Select device number [1-${#rows[@]}, default: 1]: " choice </dev/tty || choice=1
    # Strip zero padding first: bash arithmetic would read 08 as an invalid
    # octal number and, under set -e, abort the script with no message.
    choice=$(_normalize_number "$choice")
    [[ "$choice" =~ ^[0-9]+$ ]] || choice=1
    local idx=$((choice-1))
    [[ $idx -ge 0 && $idx -lt ${#rows[@]} ]] || idx=0
    DEVICE_SERIAL="${rows[$idx]#* }"
    echo -e "${GREEN}[✓] Selected device: $DEVICE_SERIAL (${rows[$idx]%% *})${NC}"
  fi
}

prompt_resolution() {
  echo ""
  echo -e "${CYAN}  Resolution:${NC}"
  echo "    1) 1280 (720p)"
  echo "    2) 800"
  echo "    3) 640 (480p)"
  echo "    4) Original (no limit)"
  echo ""
  read -rp "  Select [1-4, default: 4]: " res_choice </dev/tty || res_choice="4"
  case "$res_choice" in
    1) SCRCPY_ARGS+=("--max-size=1280") ;;
    2) SCRCPY_ARGS+=("--max-size=800") ;;
    3) SCRCPY_ARGS+=("--max-size=640") ;;
    *) ;; # no limit
  esac
}

prompt_fps() {
  echo ""
  echo -e "${CYAN}  Frame Rate:${NC}"
  echo "    1) 60 fps"
  echo "    2) 30 fps"
  echo "    3) Default (device max)"
  echo ""
  read -rp "  Select [1-3, default: 3]: " fps_choice </dev/tty || fps_choice="3"
  case "$fps_choice" in
    1) SCRCPY_ARGS+=("--max-fps=60") ;;
    2) SCRCPY_ARGS+=("--max-fps=30") ;;
    *) ;; # default
  esac
}

show_shortcuts() {
  echo ""
  echo -e "${CYAN}  === scrcpy Keyboard Shortcuts ===${NC}"
  echo ""
  echo "    Alt + H    →  Home"
  echo "    Alt + B    →  Back"
  echo "    Alt + S    →  Switch apps"
  echo "    Alt + F    →  Fullscreen"
  echo "    Alt + Up   →  Volume up"
  echo "    Alt + Down →  Volume down"
  echo "    Alt + O    →  Turn phone screen off"
  echo "    Alt + P    →  Power button"
  echo ""
}

_state_dir() {
  printf '%s\n' "${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/adb-wireless-connect"
}

# True when argv's basename is a program that legitimately runs a script handed
# to it as an argument. The kernel sets argv to [interpreter, script, args…] for
# a `#!` script, and an `env` in front of the interpreter may either stay in argv
# or exec away, so the script's own name is not reliably at a fixed index.
_is_interpreter_name() {
  case "${1##*/}" in
    env|sh|bash|dash|ksh|zsh|csh|tcsh|busybox) return 0 ;;
  esac
  return 1
}

# True only when the recorded PID is positively identified as a scrcpy process.
# `kill -0` would only prove that *something* owns the PID: the PID file is
# stranded by a SIGKILLed launcher, a reboot, or a plain scrcpy quit, and the
# number it names may since have been recycled by an unrelated process. Reading
# the command line is what makes the refusal and the --force kill safe.
# Anything short of a positive match counts as "not our scrcpy".
#
# The match is positional, not a search. Scanning every field accepted anything
# that merely mentions scrcpy — `find / -name scrcpy` and `vim scrcpy` were both
# identified as a live session, and --force then SIGTERMed and SIGKILLed them.
# So walk argv from the left, accepting only interpreter names, and stop at the
# first field that is neither an interpreter nor scrcpy itself. The walk has to
# END on scrcpy: that is the executable, not a word it was handed.
#
# Why not a fixed window of the first one or two fields instead: the kernel sets
# argv for a `#!/usr/bin/env bash` script to [interpreter, shebang-arg, script,
# args…], so the same wrapper measures at index 2 while `env` is still in argv
# and at index 1 once `env` execs away — which is the usual steady state, and is
# what a wrapper on this host actually shows. A window hard-coded to 0-1 accepts
# the second shape and rejects the first, reporting a live session as stale and
# letting a second scrcpy start on top of it. Walking accepts both.
#
# A prefix that is not an interpreter name ends the walk as a rejection, which is
# the point: the process then is not scrcpy, whatever it was told to run. The
# launcher never records such a PID, because `nohup` and `env` both exec away
# before the session is identified.
_process_is_scrcpy() {
  local pid=$1 cmdline field
  local -a fields=()
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  # NUL-separated argv, so translate the separators before splitting.
  cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
  read -r -a fields <<<"$cmdline"
  # argv[0] of the real binary, or the script path of a #! wrapper, reached by
  # stepping over the interpreters in front of it. Nothing after scrcpy is
  # examined, so an argument that happens to be named scrcpy cannot match.
  for field in "${fields[@]}"; do
    [[ "${field##*/}" == "scrcpy" ]] && return 0
    _is_interpreter_name "$field" || return 1
  done
  return 1
}

# Refuse to start a second scrcpy against the same setup while one is already
# running. A PID file that does not positively identify a live scrcpy is stale
# and never blocks a launch: overwriting a stale PID file is harmless, whereas
# refusing or killing a stranger's process is not.
_check_existing_session() {
  local pid_file=$1 recorded
  [[ -s "$pid_file" ]] || return 0
  # `read` returns non-zero for a file with no trailing newline even though it
  # assigns the value, so a `|| recorded=""` fallback would discard a valid PID.
  read -r recorded <"$pid_file" || true
  # One gate for both decisions below: never refuse, and never signal, a process
  # that is not positively identified as scrcpy.
  _process_is_scrcpy "$recorded" || return 0

  if [[ $SCRCPY_FORCE -eq 1 ]]; then
    echo -e "${YELLOW}[!] --force given: stopping the scrcpy session already running (PID: $recorded).${NC}"
    kill "$recorded" 2>/dev/null || true
    _wait_for_exit "$recorded" || {
      echo -e "${YELLOW}[!] Could not stop the scrcpy session (PID: $recorded).${NC}"
      echo "  Run 'kill -9 $recorded' by hand, then re-run this script."
      return 1
    }
    return 0
  fi

  echo -e "${YELLOW}[!] A scrcpy session is already running (PID: $recorded).${NC}"
  echo ""
  echo "  Stop it first:  kill $recorded"
  echo "  Or re-run with --force to stop it and start a new one."
  echo -e "${CYAN}  PID file: $pid_file${NC}"
  return 1
}

# Give a signalled process a moment to go away, then insist.
_wait_for_exit() {
  local pid=$1 i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    # Re-check identity before escalating. SIGTERM was sent after the same gate,
    # but a second has passed: the PID could have been recycled, and SIGKILL
    # cannot be caught, retried, or refused by whatever now holds it. Refusing
    # here is reported to the user by the caller's own failure message.
    if ! _process_is_scrcpy "$pid"; then
      return 1
    fi
    kill -9 "$pid" 2>/dev/null || true
    sleep 0.1
  fi
  ! kill -0 "$pid" 2>/dev/null
}

# Keep the log directory bounded: retain the newest $1 scrcpy.*.log files, plus
# the current launch's log even if it is not among the newest.
_prune_logs() {
  local keep=$1 current=$2 dir=$3
  local -a logs=()
  local log
  while IFS= read -r log; do
    [[ -n "$log" ]] || continue
    [[ "$log" == "$current" ]] && continue
    logs+=("$log")
  done < <(ls -1t "$dir"/scrcpy.*.log 2>/dev/null)
  [[ ${#logs[@]} -le $keep ]] && return 0
  for log in "${logs[@]:$keep}"; do
    rm -f "$log" 2>/dev/null || true
  done
  return 0
}

# Record the session's PID, or fail loudly and stop the session again.
#
# This guard is explicit because `set -e` cannot be. Both callers sit inside
# functions that main invokes as a `||` operand (`launch_scrcpy || status=$?`),
# and bash suspends errexit for the entire dynamic extent of a function used that
# way — including everything it calls. So an unwritable state directory would
# otherwise be reported as a successful launch, printing "[✓] scrcpy started"
# and a PID file path with no PID file behind it, which defeats the session
# lifecycle silently. The same hazard is documented in docs/BUILD.md for
# start.sh's step_disconnect_usb_prompt; it is the same hazard.
#
# A session that cannot be recorded is stopped rather than left running: the
# launcher's invariant is that every scrcpy it starts is either in the PID file
# or not running — the same one the mktemp guard relies on by refusing to launch
# at all when the directory is unusable.
_record_session_pid() {
  local pid_file=$1 scrcpy_pid=$2 log_file=$3 log_dir
  if printf '%s\n' "$scrcpy_pid" >"$pid_file"; then
    return 0
  fi
  log_dir=${pid_file%/*}
  echo -e "${YELLOW}[!] Could not write the PID file: $pid_file${NC}"
  echo ""
  echo "  The state directory must exist and be writable. Check it with:"
  echo "    ls -ld '$log_dir'"
  echo "  scrcpy was started but has been stopped again: a session this launcher"
  echo "  cannot record is a session it cannot stop or guard later either."
  echo "  Fix that, or point XDG_STATE_HOME somewhere writable, then re-run."
  echo -e "${CYAN}    Log: $log_file${NC}"
  kill "$scrcpy_pid" 2>/dev/null || true
  # This path is a failed launch, which is exactly when a user retries, so the
  # log directory has to stay bounded here too.
  _prune_logs 10 "$log_file" "$log_dir"
  return 1
}

# Foreground mode: block until scrcpy exits, then hand its status back.
_launch_and_wait() {
  local log_file=$1 pid_file=$2
  local scrcpy_pid exit_status

  scrcpy -s "$DEVICE_SERIAL" "${SCRCPY_ARGS[@]}" >"$log_file" 2>&1 &
  scrcpy_pid=$!
  _record_session_pid "$pid_file" "$scrcpy_pid" "$log_file" || return 1

  # `set +e` documents that the wait below is expected to report a non-zero
  # status. It is belt-and-braces: the caller already invokes this function as a
  # `||` operand, so errexit is suspended here regardless, and the `set -e` that
  # used to follow it re-enabled a flag that was never set.
  set +e
  wait "$scrcpy_pid"
  exit_status=$?
  rm -f "$pid_file"

  if [[ $exit_status -ne 0 ]]; then
    echo -e "${YELLOW}[!] scrcpy exited with status: $exit_status${NC}"
    if [[ -s "$log_file" ]]; then
      sed 's/^/    /' "$log_file"
    fi
    echo -e "${CYAN}    Log: $log_file${NC}"
  else
    echo -e "${GREEN}[✓] scrcpy exited cleanly.${NC}"
    echo -e "${CYAN}    Log: $log_file${NC}"
  fi
  return "$exit_status"
}

launch_scrcpy() {
  echo -e "${YELLOW}[*] Launching scrcpy...${NC}"
  if [[ ${#SCRCPY_ARGS[@]} -gt 0 ]]; then
    echo -e "${CYAN}    Args: ${SCRCPY_ARGS[*]}${NC}"
  fi

  local log_dir log_file pid_file scrcpy_pid exit_status
  log_dir=$(_state_dir)
  mkdir -p "$log_dir"
  pid_file="$log_dir/scrcpy.pid"

  if ! _check_existing_session "$pid_file"; then
    return 1
  fi

  # An unwritable or missing state directory must be reported as itself. Left
  # unguarded, mktemp's failure leaves log_file empty and the launch goes on to
  # blame scrcpy for a failure that never happened.
  if ! log_file=$(mktemp "$log_dir/scrcpy.XXXXXX.log"); then
    echo -e "${YELLOW}[!] Could not create a log file in $log_dir.${NC}"
    echo ""
    echo "  The state directory must exist and be writable. Check it with:"
    echo "    ls -ld '$log_dir'"
    echo "  Fix that, or point XDG_STATE_HOME somewhere writable, then re-run."
    return 1
  fi

  if [[ $SCRCPY_WAIT -eq 1 ]]; then
    echo -e "${CYAN}    Running in the foreground; press Ctrl+C or close the scrcpy window to stop.${NC}"
    echo -e "${CYAN}    Log: $log_file${NC}"
    echo -e "${CYAN}    PID file: $pid_file${NC}"
    # Prune before blocking: a foreground session can run for hours, and this
    # launch's own log is already the newest, so nothing useful is lost.
    _prune_logs 10 "$log_file" "$log_dir"
    # Propagate scrcpy's status explicitly rather than relying on the caller
    # having suspended errexit around this function.
    _launch_and_wait "$log_file" "$pid_file" || return $?
    return 0
  fi

  nohup scrcpy -s "$DEVICE_SERIAL" "${SCRCPY_ARGS[@]}" >"$log_file" 2>&1 &
  scrcpy_pid=$!
  _record_session_pid "$pid_file" "$scrcpy_pid" "$log_file" || return 1

  sleep "$SCRCPY_TIMEOUT"
  if ! kill -0 "$scrcpy_pid" 2>/dev/null; then
    # `set +e` is belt-and-braces for the same reason as in _launch_and_wait:
    # errexit is already suspended by the `launch_scrcpy || status=$?` caller, so
    # the `set -e` that used to close this pair re-enabled a flag never set.
    set +e
    wait "$scrcpy_pid"
    exit_status=$?
    [[ $exit_status -ne 0 ]] || exit_status=1

    echo -e "${YELLOW}[!] scrcpy failed to start (status: $exit_status).${NC}"
    if [[ -s "$log_file" ]]; then
      sed 's/^/    /' "$log_file"
    fi
    echo -e "${CYAN}    Log: $log_file${NC}"
    # Prune here too: a device that fails to start is exactly the case where a
    # user retries, and the log directory has to stay bounded either way.
    _prune_logs 10 "$log_file" "$log_dir"
    rm -f "$pid_file"
    return "$exit_status"
  fi

  echo -e "${GREEN}[✓] scrcpy started and passed the startup check (PID: $scrcpy_pid)${NC}"
  echo -e "${CYAN}    Log: $log_file${NC}"
  echo -e "${CYAN}    PID file: $pid_file${NC}"
  echo "    Stop it with:  kill $scrcpy_pid"
  _prune_logs 10 "$log_file" "$log_dir"
}

main() {
  print_banner
  check_adb
  check_scrcpy
  detect_device

  if [[ ${#SCRCPY_ARGS[@]} -eq 0 ]]; then
    prompt_resolution
    prompt_fps
  fi

  show_shortcuts
  # Propagate scrcpy's own status: the existing suite asserts 42/43 for a failed
  # startup, and --wait reports the status of a session that ran and then died.
  local status=0
  launch_scrcpy || status=$?

  if [[ $status -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}  Launcher finished. Check the scrcpy window or log for runtime status.${NC}"
  fi
  return "$status"
}

main
