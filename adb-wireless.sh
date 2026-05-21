#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
  clear
  echo -e "${CYAN}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║        ADB Wireless Connect Script           ║"
  echo "  ║     Automate wireless ADB connection         ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

check_adb() {
  if ! command -v adb &>/dev/null; then
    echo -e "${YELLOW}[!] adb not found on this system.${NC}"
    echo ""
    echo "  Install ADB:"
    echo "    sudo apt install adb              # Debian/Ubuntu"
    echo "    sudo dnf install android-tools    # Fedora"
    echo "    sudo pacman -S android-tools      # Arch"
    echo ""
    echo -e "${YELLOW}  After installing, re-run this script.${NC}"
    exit 1
  fi
  echo -e "${GREEN}[✓] adb detected${NC}"
}

check_scrcpy() {
  if ! command -v scrcpy &>/dev/null; then
    echo ""
    echo -e "${YELLOW}[!] scrcpy not found. Install it:${NC}"
    echo "    sudo apt install scrcpy              # Debian/Ubuntu"
    echo "    sudo dnf install scrcpy              # Fedora"
    echo "    sudo pacman -S scrcpy                # Arch"
    echo ""
    read -rp "  Press Enter after installing scrcpy, or Ctrl+C to skip..."
    if ! command -v scrcpy &>/dev/null; then
      echo -e "${YELLOW}[!] scrcpy still not found. Skipping scrcpy launch.${NC}"
      return 1
    fi
  fi
  echo -e "${GREEN}[✓] scrcpy detected${NC}"
  return 0
}

step_usb_prompt() {
  echo ""
  echo -e "${YELLOW}  === STEP 1: Connect your phone via USB ===${NC}"
  echo ""
  echo "  Ensure the following are enabled on your phone:"
  echo "    • Developer Options"
  echo "    • USB Debugging"
  echo "    • Wi-Fi Hotspot (turned on)"
  echo "    • USB Tethering (usually in Settings → Network & Internet)"
  echo ""
  read -rp "  Press Enter once the phone is connected and ready..."
  echo ""
}

step_get_device_id() {
  echo -e "${YELLOW}[*] Checking for connected devices...${NC}"
  local id
  id=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
  if [[ -z "$id" ]]; then
    echo -e "${YELLOW}[!] No device found. Make sure USB debugging is enabled and the phone is connected.${NC}"
    exit 1
  fi
  echo -e "${GREEN}[✓] Device detected: $id${NC}"
  DEVICE_ID="$id"
}

step_get_ip() {
  echo -e "${YELLOW}[*] Extracting IP address from rmnet_data0...${NC}"
  local ip
  ip=$(adb -s "$DEVICE_ID" shell ip addr show rmnet_data0 2>/dev/null | grep -oP 'inet \K[\d.]+' || true)
  if [[ -z "$ip" ]]; then
    echo -e "${YELLOW}[!] Could not extract IP from rmnet_data0.${NC}"
    echo "    Possible reasons: mobile data is off, or the interface name differs."
    echo "    Run 'adb shell ip addr show' to check available interfaces."
    exit 1
  fi
  echo -e "${GREEN}[✓] IP address: $ip${NC}"
  DEVICE_IP="$ip"
}

step_tcpip() {
  echo -e "${YELLOW}[*] Switching device to TCP/IP mode on port 5555...${NC}"
  adb -s "$DEVICE_ID" tcpip 5555
  echo -e "${GREEN}[✓] TCP/IP mode enabled${NC}"
  sleep 2
}

step_connect() {
  echo -e "${YELLOW}[*] Connecting to $DEVICE_IP:5555...${NC}"
  local out
  out=$(adb connect "$DEVICE_IP:5555" 2>&1)
  echo "    $out"
  if echo "$out" | grep -qi "failed\|unable\|error"; then
    echo -e "${YELLOW}[!] Connection failed. Retrying in 3 seconds...${NC}"
    sleep 3
    out=$(adb connect "$DEVICE_IP:5555" 2>&1)
    echo "    $out"
  fi
}

step_verify_wireless() {
  echo ""
  echo -e "${YELLOW}[*] Current ADB devices:${NC}"
  adb devices
}

step_disconnect_usb() {
  echo ""
  read -rp "  Now disconnect the USB cable from your phone, then press Enter..."
  echo ""
  echo -e "${YELLOW}[*] Verifying wireless connection...${NC}"
  adb devices
  if adb devices | awk 'NR>1' | grep -q "$DEVICE_IP:5555"; then
    echo ""
    echo -e "${GREEN}  ✓ Connected wirelessly!${NC}"
  else
    echo ""
    echo -e "${YELLOW}  [!] Device not showing as connected wirelessly. Check the IP and try again.${NC}"
  fi
}

step_show_shortcuts() {
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

step_launch_scrcpy() {
  echo -e "${YELLOW}[*] Launching scrcpy in the background...${NC}"
  nohup scrcpy >/dev/null 2>&1 &
  echo -e "${GREEN}[✓] scrcpy started (PID: $!)${NC}"
  echo "    Type 'fg' to bring it to the foreground if needed."
}

main() {
  print_banner
  check_adb
  step_usb_prompt
  adb kill-server 2>/dev/null || true
  adb start-server 2>/dev/null || true
  step_get_device_id
  step_get_ip
  step_tcpip
  step_connect
  step_verify_wireless
  step_disconnect_usb
  step_show_shortcuts

  if check_scrcpy; then
    step_launch_scrcpy
  fi

  echo ""
  echo -e "${GREEN}  Done! Enjoy wireless ADB.${NC}"
}

main
