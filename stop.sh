#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DISCONNECT_ALL=false
KILL_SERVER=false

check_adb() {
  if ! command -v adb &>/dev/null; then
    echo -e "${YELLOW}[!] adb not found on this system.${NC}"
    echo ""
    echo "  Install ADB:"
    echo "    pkexec apt install adb             # Debian/Ubuntu/Pop!_OS"
    echo "    pkexec dnf install android-tools   # Fedora"
    echo "    pkexec pacman -S android-tools     # Arch"
    echo ""
    echo -e "${YELLOW}  After installing, re-run this script.${NC}"
    exit 1
  fi
}

show_help() {
  echo -e "${CYAN}ADB Wireless Connect - stop.sh${NC}"
  echo ""
  echo "Usage: ./stop.sh [options]"
  echo ""
  echo "Options:"
  echo "  -a, --all     Disconnect all wireless ADB connections immediately"
  echo "  -k, --kill    Kill the ADB server completely (adb kill-server)"
  echo "  -h, --help    Show this help message"
  echo ""
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -a|--all) DISCONNECT_ALL=true; shift ;;
    -k|--kill) KILL_SERVER=true; shift ;;
    -h|--help) show_help; exit 0 ;;
    *) echo -e "${YELLOW}[!] Unknown option: $1${NC}"; show_help; exit 1 ;;
  esac
done

print_banner() {
  echo ""
  echo -e "${CYAN}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║        ADB Wireless Stop / Cleanup           ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# Read one serial's state out of a cached "adb devices" dump. A serial that is
# not in the dump is still a wireless target (the filter matches on the serial
# alone), so it is reported as "unknown" rather than presented as active.
_device_state() {
  local serial=$1 dump=$2 state
  state=$(printf '%s\n' "$dump" | awk -v s="$serial" 'NR>1 && $1 == s { print $2; exit }')
  printf '%s\n' "${state:-unknown}"
}

main() {
  print_banner
  check_adb

  if $KILL_SERVER; then
    echo -e "${YELLOW}[*] Killing ADB server...${NC}"
    if ! adb kill-server; then
      echo -e "${YELLOW}[!] adb kill-server failed. Try 'adb kill-server' manually.${NC}"
      return 1
    fi
    echo -e "${GREEN}[✓] ADB server killed.${NC}"
    return 0
  fi

  local dev
  # One adb call: the wireless list and the per-entry state labels are both
  # derived from this snapshot, so the listing can never contradict itself.
  local devices_out
  devices_out=$(adb devices || true)

  local wireless_devices
  mapfile -t wireless_devices < <(printf '%s\n' "$devices_out" | awk 'NR>1 && $1 ~ /:[0-9]+$/ {print $1}')

  if [[ ${#wireless_devices[@]} -eq 0 ]]; then
    echo -e "${YELLOW}[!] No active wireless ADB connections found.${NC}"
    echo ""
    printf '%s\n' "$devices_out"
    echo ""
    echo "Select an action:"
    echo "  1) Restart ADB server completely"
    echo "  2) Exit"
    echo ""
    read -rp "Enter choice [1-2]: " choice </dev/tty || choice="2"
    case "$choice" in
      1)
        echo -e "${YELLOW}[*] Restarting ADB server...${NC}"
        adb kill-server
        adb start-server
        echo -e "${GREEN}[✓] ADB server restarted.${NC}"
        ;;
      *)
        echo -e "${YELLOW}Exiting.${NC}"
        ;;
    esac
    exit 0
  fi

  echo -e "${YELLOW}[*] Wireless ADB targets:${NC}"
  for dev in "${wireless_devices[@]}"; do
    echo "    • $dev ($(_device_state "$dev" "$devices_out"))"
  done
  echo ""

  if $DISCONNECT_ALL; then
    for dev in "${wireless_devices[@]}"; do
      echo -e "${YELLOW}[*] Disconnecting $dev...${NC}"
      adb disconnect "$dev"
    done
    echo -e "${GREEN}[✓] All wireless ADB connections disconnected.${NC}"
    exit 0
  fi

  echo "Select an action:"
  echo "  1) Disconnect all wireless ADB targets"
  echo "  2) Kill and restart ADB server completely"
  echo "  3) Cancel"
  echo ""
  read -rp "Enter choice [1-3]: " choice </dev/tty || choice="3"

  case "$choice" in
    1)
      for dev in "${wireless_devices[@]}"; do
        echo -e "${YELLOW}[*] Disconnecting $dev...${NC}"
        adb disconnect "$dev"
      done
      echo -e "${GREEN}[✓] Disconnected.${NC}"
      ;;
    2)
      echo -e "${YELLOW}[*] Restarting ADB server...${NC}"
      adb kill-server
      adb start-server
      echo -e "${GREEN}[✓] ADB server restarted.${NC}"
      ;;
    *)
      echo -e "${YELLOW}Cancelled.${NC}"
      ;;
  esac
}

main
