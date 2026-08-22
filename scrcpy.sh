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
  echo ""
  echo "Options:"
  echo "  -a, --args ...      Pass custom arguments to scrcpy (must be final option)"
  echo "  -s, --serial S      Specify device serial (e.g. 192.168.1.50:5555)"
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
  clear 2>/dev/null || true
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
    echo "    sudo apt install scrcpy              # Debian/Ubuntu/Pop!_OS"
    echo "    sudo dnf install scrcpy              # Fedora"
    echo "    sudo pacman -S scrcpy                # Arch"
    echo ""
    echo -e "${YELLOW}  After installing, re-run this script.${NC}"
    exit 1
  fi
  echo -e "${GREEN}[✓] scrcpy detected${NC}"
}

detect_device() {
  if [[ -n "$DEVICE_SERIAL" ]]; then
    if ! adb devices | awk 'NR>1 && $2=="device" {print $1}' | grep -q "^${DEVICE_SERIAL}$"; then
      echo -e "${YELLOW}[!] Specified device $DEVICE_SERIAL is not connected or not authorized.${NC}"
      echo ""
      echo "  Connected devices:"
      adb devices | awk 'NR>1 && $2=="device" {print "    " $1}'
      exit 1
    fi
    echo -e "${GREEN}[✓] Using specified device: $DEVICE_SERIAL${NC}"
    return 0
  fi

  local devices
  mapfile -t devices < <(adb devices | awk 'NR>1 && $2=="device" && $1 ~ /:[0-9]+$/ {print $1}')

  if [[ ${#devices[@]} -eq 0 ]]; then
    echo -e "${YELLOW}[!] No wireless ADB devices found.${NC}"
    echo ""
    echo "  Connect a device first:"
    echo "    ./start.sh              # USB setup"
    echo "    adb pair <ip:port>      # Android 11+ pairing"
    echo ""
    exit 1
  elif [[ ${#devices[@]} -eq 1 ]]; then
    DEVICE_SERIAL="${devices[0]}"
    echo -e "${GREEN}[✓] Device detected: $DEVICE_SERIAL${NC}"
  else
    echo -e "${YELLOW}[*] Multiple wireless devices detected:${NC}"
    for i in "${!devices[@]}"; do
      echo "    $((i+1))) ${devices[$i]}"
    done
    read -rp "  Select device number [1-${#devices[@]}]: " choice </dev/tty || choice=1
    local idx=$((choice-1))
    DEVICE_SERIAL="${devices[$idx]:-${devices[0]}}"
    echo -e "${GREEN}[✓] Selected device: $DEVICE_SERIAL${NC}"
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
    nohup scrcpy -s "$DEVICE_SERIAL" "${SCRCPY_ARGS[@]}" >/dev/null 2>&1 &
  else
    nohup scrcpy -s "$DEVICE_SERIAL" >/dev/null 2>&1 &
  fi
  echo -e "${GREEN}[✓] scrcpy started (PID: $!)${NC}"
}

main() {
  print_banner
  check_scrcpy
  detect_device

  if [[ ${#SCRCPY_ARGS[@]} -eq 0 ]]; then
    prompt_resolution
    prompt_fps
  fi

  show_shortcuts
  launch_scrcpy

  echo ""
  echo -e "${GREEN}  Done! Enjoy screen mirroring.${NC}"
}

main
