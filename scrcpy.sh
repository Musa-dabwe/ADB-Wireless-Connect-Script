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
  echo "  -t, --timeout S     Startup grace period in seconds (default: 2)"
  echo "  -w, --wait          Run in the foreground and exit with scrcpy's status"
  echo "  -f, --force         Kill a scrcpy session already running, then start a new one"
  echo "  -h, --help          Show this help message"
  echo ""
  echo "Session notes:"
  echo "  Without --wait the launcher backgrounds scrcpy, waits $SCRCPY_TIMEOUT seconds to"
  echo "  confirm it survived startup, prints the log and PID file paths, and exits 0."
  echo "  With --wait it blocks until scrcpy exits and exits with scrcpy's own status,"
  echo "  so a mid-session crash is visible in your terminal."
  echo ""
}

# Parse CLI flags
DEVICE_SERIAL=""
SCRCPY_TIMEOUT=2
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
        echo "  Use a plain value such as 2 or 0.5; the default is 2."
        show_help
        exit 1
      fi
      # A value like 0 or 0.00 passes the format check but means "no grace
      # period at all", which would race a healthy slow start; reject it.
      if ! [[ "$2" =~ [1-9] ]]; then
        echo -e "${YELLOW}[!] --timeout must be greater than zero, got: $2${NC}"
        echo "  Use a positive value such as 2 or 0.5; the default is 2."
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

# Refuse to start a second scrcpy against the same setup while one is already
# running. A PID file whose process is gone is stale and never blocks a launch.
_check_existing_session() {
  local pid_file=$1 recorded
  [[ -s "$pid_file" ]] || return 0
  read -r recorded <"$pid_file" || recorded=""
  # A PID file that does not hold a plain number cannot be probed; treat it as
  # stale and let the launch overwrite it.
  if [[ ! "$recorded" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  if kill -0 "$recorded" 2>/dev/null; then
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
  fi

  # Stale PID file: the process is gone, so overwrite it silently below.
  return 0
}

# Give a signalled process a moment to go away, then insist.
_wait_for_exit() {
  local pid=$1 i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
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

# Foreground mode: block until scrcpy exits, then hand its status back.
_launch_and_wait() {
  local log_file=$1 pid_file=$2
  local scrcpy_pid exit_status

  scrcpy -s "$DEVICE_SERIAL" "${SCRCPY_ARGS[@]}" >"$log_file" 2>&1 &
  scrcpy_pid=$!
  printf '%s\n' "$scrcpy_pid" >"$pid_file"

  set +e
  wait "$scrcpy_pid"
  exit_status=$?
  set -e
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

  log_file=$(mktemp "$log_dir/scrcpy.XXXXXX.log")

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
  printf '%s\n' "$scrcpy_pid" >"$pid_file"

  sleep "$SCRCPY_TIMEOUT"
  if ! kill -0 "$scrcpy_pid" 2>/dev/null; then
    set +e
    wait "$scrcpy_pid"
    exit_status=$?
    set -e
    [[ $exit_status -ne 0 ]] || exit_status=1

    echo -e "${YELLOW}[!] scrcpy failed to start (status: $exit_status).${NC}"
    if [[ -s "$log_file" ]]; then
      sed 's/^/    /' "$log_file"
    fi
    echo -e "${CYAN}    Log: $log_file${NC}"
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
