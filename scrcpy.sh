#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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
  echo "  -h, --help          Show this help message"
  echo ""
}

# Parse CLI flags
DEVICE_SERIAL=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -a|--args)
      shift
      if [[ "$#" -eq 0 ]]; then
        echo -e "${YELLOW}[!] Option --args requires at least one argument.${NC}"
        show_help
        exit 1
      fi
      for _a in "$@"; do
        if [[ "$_a" == "-s" || "$_a" == "--serial" ]]; then
          echo -e "${YELLOW}[!] -s/--serial must come before -a/--args.${NC}"
          show_help
          exit 1
        fi
      done
      SCRCPY_ARGS=("$@")
      shift "$#"
      ;;
    -s|--serial)
      if [[ -z "$2" || "$2" =~ ^- ]]; then
        echo -e "${YELLOW}[!] Option $1 requires a device serial.${NC}"
        show_help
        exit 1
      fi
      DEVICE_SERIAL="$2"
      shift 2
      ;;
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
  echo -e "${GREEN}[✓] scrcpy detected${NC}"
}

check_adb() {
  if ! command -v adb &>/dev/null; then
    echo -e "${YELLOW}[!] adb not found on this system.${NC}"
    echo ""
    echo "  Install Android platform tools:"
    echo "    pkexec apt install adb               # Debian/Ubuntu/Pop!_OS"
    echo "    pkexec dnf install android-tools       # Fedora"
    echo "    pkexec pacman -S android-tools        # Arch"
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
    if ! _connected_devices | grep -q "^${DEVICE_SERIAL}$"; then
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

launch_scrcpy() {
  echo -e "${YELLOW}[*] Launching scrcpy...${NC}"
  if [[ ${#SCRCPY_ARGS[@]} -gt 0 ]]; then
    echo -e "${CYAN}    Args: ${SCRCPY_ARGS[*]}${NC}"
  fi

  local log_dir log_file scrcpy_pid exit_status
  log_dir="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/adb-wireless-connect"
  mkdir -p "$log_dir"
  log_file=$(mktemp "$log_dir/scrcpy.XXXXXX.log")

  nohup scrcpy -s "$DEVICE_SERIAL" "${SCRCPY_ARGS[@]}" >"$log_file" 2>&1 &
  scrcpy_pid=$!

  sleep 1.25
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
    return "$exit_status"
  fi

  echo -e "${GREEN}[✓] scrcpy started and passed the startup check (PID: $scrcpy_pid)${NC}"
  echo -e "${CYAN}    Log: $log_file${NC}"
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
  launch_scrcpy

  echo ""
  echo -e "${GREEN}  Launcher finished. Check the scrcpy window or log for runtime status.${NC}"
}

main
