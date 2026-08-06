#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DISCONNECT_ALL=false

check_adb() {
  if ! command -v adb &>/dev/null; then
    echo -e "${YELLOW}[!] adb not found on this system.${NC}"
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
    -k|--kill)
      check_adb
      echo -e "${YELLOW}[*] Killing ADB server...${NC}"
      adb kill-server
      echo -e "${GREEN}[✓] ADB server killed.${NC}"
      exit 0
      ;;
    -h|--help) show_help; exit 0 ;;
    *) echo -e "${YELLOW}[!] Unknown option: $1${NC}"; show_help; exit 1 ;;
  esac
done

print_banner() {
  clear 2>/dev/null || true
  echo -e "${CYAN}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║        ADB Wireless Stop / Cleanup           ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

main() {
  print_banner
  check_adb

  local wireless_devices
  mapfile -t wireless_devices < <(adb devices | awk 'NR>1 && $1 ~ /:[0-9]+$/ {print $1}')

  if [[ ${#wireless_devices[@]} -eq 0 ]]; then
    echo -e "${YELLOW}[!] No active wireless ADB connections found.${NC}"
    echo ""
    adb devices
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

  echo -e "${YELLOW}[*] Active wireless ADB connections:${NC}"
  for dev in "${wireless_devices[@]}"; do
    echo "    • $dev"
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
