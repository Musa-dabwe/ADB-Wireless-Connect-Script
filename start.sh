#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PORT=5555
LAUNCH_SCRCPY=true
SCRCPY_ARGS=""

show_help() {
  echo -e "${CYAN}ADB Wireless Connect - start.sh${NC}"
  echo ""
  echo "Usage: ./start.sh [options]"
  echo ""
  echo "Options:"
  echo "  -n, --no-scrcpy       Skip launching scrcpy screen mirroring"
  echo "  -a, --scrcpy-args S   Pass custom arguments to scrcpy (e.g. --scrcpy-args \"--turn-screen-off --stay-awake\")"
  echo "  -p, --port P          Specify target TCP port (default: 5555)"
  echo "  -h, --help            Show this help message"
  echo ""
  exit 0
}

# Parse CLI flags
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -n|--no-scrcpy) LAUNCH_SCRCPY=false; shift ;;
    -a|--scrcpy-args) SCRCPY_ARGS="$2"; shift 2 ;;
    -p|--port) PORT="$2"; shift 2 ;;
    -h|--help) show_help ;;
    *) echo -e "${YELLOW}[!] Unknown option: $1${NC}"; show_help ;;
  esac
done

print_banner() {
  clear 2>/dev/null || true
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
    echo "    sudo apt install adb              # Debian/Ubuntu/Pop!_OS"
    echo "    sudo dnf install android-tools    # Fedora"
    echo "    sudo pacman -S android-tools      # Arch"
    echo ""
    echo -e "${YELLOW}  After installing, re-run this script.${NC}"
    exit 1
  fi
  echo -e "${GREEN}[✓] adb detected${NC}"
}

check_scrcpy() {
  if ! $LAUNCH_SCRCPY; then
    return 1
  fi
  if ! command -v scrcpy &>/dev/null; then
    echo ""
    echo -e "${YELLOW}[!] scrcpy not found. Install it:${NC}"
    echo "    sudo apt install scrcpy              # Debian/Ubuntu/Pop!_OS"
    echo "    sudo dnf install scrcpy              # Fedora"
    echo "    sudo pacman -S scrcpy                # Arch"
    echo ""
    read -rp "  Press Enter after installing scrcpy, or Ctrl+C to skip..." </dev/tty || true
    if ! command -v scrcpy &>/dev/null; then
      echo -e "${YELLOW}[!] scrcpy still not found. Skipping scrcpy launch.${NC}"
      return 1
    fi
  fi
  echo -e "${GREEN}[✓] scrcpy detected${NC}"
  return 0
}

detect_usb_device() {
  local devices
  mapfile -t devices < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  
  if [[ ${#devices[@]} -eq 0 ]]; then
    echo ""
    return 1
  elif [[ ${#devices[@]} -eq 1 ]]; then
    DEVICE_ID="${devices[0]}"
    echo -e "${GREEN}[✓] USB device detected: $DEVICE_ID${NC}"
    return 0
  else
    echo -e "${YELLOW}[*] Multiple USB devices detected:${NC}"
    for i in "${!devices[@]}"; do
      echo "    $((i+1))) ${devices[$i]}"
    done
    read -rp "  Select device number [1-${#devices[@]}]: " choice </dev/tty || choice=1
    local idx=$((choice-1))
    DEVICE_ID="${devices[$idx]:-${devices[0]}}"
    echo -e "${GREEN}[✓] Selected device: $DEVICE_ID${NC}"
    return 0
  fi
}

handle_android11_pairing() {
  echo -e "${YELLOW}  === Android 11+ Wireless Pairing Mode ===${NC}"
  echo "  1. On your phone: Go to Developer Options → Wireless Debugging (turn ON)."
  echo "  2. Tap 'Pair device with pairing code'."
  echo ""
  read -rp "  Enter phone Wi-Fi IP and Pairing Port (e.g. 192.168.1.50:37123): " pair_addr </dev/tty || true
  read -rp "  Enter 6-digit Pairing Code: " pair_code </dev/tty || true

  if [[ -n "$pair_addr" && -n "$pair_code" ]]; then
    echo -e "${YELLOW}[*] Pairing with $pair_addr...${NC}"
    adb pair "$pair_addr" "$pair_code"
    echo -e "${GREEN}[✓] Pairing successful!${NC}"
    echo ""
    read -rp "  Enter target Connect Port shown on main Wireless Debugging page (e.g. 5555 or 42123): " target_port </dev/tty || target_port=5555
    DEVICE_IP="${pair_addr%%:*}"
    PORT="${target_port:-5555}"
  else
    echo -e "${YELLOW}[!] Pairing details missing. Exiting.${NC}"
    exit 1
  fi
}

step_get_ip() {
  echo -e "${YELLOW}[*] Extracting device IP address...${NC}"
  local ip=""

  # Try rmnet_data0 first
  ip=$(adb -s "$DEVICE_ID" shell ip addr show rmnet_data0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n1 || true)

  # Fallback to ip route destination
  if [[ -z "$ip" ]]; then
    ip=$(adb -s "$DEVICE_ID" shell "ip route get 1.1.1.1 2>/dev/null" | grep -oP 'src \K[\d.]+' | head -n1 || true)
  fi

  # Fallback to wlan0 / wlan1 / ap0 / rndis0
  if [[ -z "$ip" ]]; then
    ip=$(adb -s "$DEVICE_ID" shell ip addr 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '^127\.' | head -n1 || true)
  fi

  if [[ -z "$ip" ]]; then
    echo -e "${YELLOW}[!] Could not auto-detect device IP address.${NC}"
    read -rp "  Enter device IP address manually: " ip </dev/tty || true
    if [[ -z "$ip" ]]; then
      echo -e "${YELLOW}[!] No IP provided. Exiting.${NC}"
      exit 1
    fi
  fi

  echo -e "${GREEN}[✓] Target IP address: $ip${NC}"
  DEVICE_IP="$ip"
}

step_tcpip() {
  echo -e "${YELLOW}[*] Switching device to TCP/IP mode on port $PORT...${NC}"
  adb -s "$DEVICE_ID" tcpip "$PORT"
  echo -e "${GREEN}[✓] TCP/IP mode enabled${NC}"
  sleep 2
}

step_connect() {
  echo -e "${YELLOW}[*] Connecting to $DEVICE_IP:$PORT...${NC}"
  local out
  out=$(adb connect "$DEVICE_IP:$PORT" 2>&1)
  echo "    $out"
  if echo "$out" | grep -qi "failed\|unable\|error"; then
    echo -e "${YELLOW}[!] Connection failed. Retrying in 3 seconds...${NC}"
    sleep 3
    out=$(adb connect "$DEVICE_IP:$PORT" 2>&1)
    echo "    $out"
  fi
}

step_verify_wireless() {
  echo ""
  echo -e "${YELLOW}[*] Current ADB devices:${NC}"
  adb devices
}

step_disconnect_usb_prompt() {
  echo ""
  read -rp "  Now disconnect the USB cable from your phone, then press Enter..." </dev/tty || true
  echo ""
  echo -e "${YELLOW}[*] Verifying wireless connection...${NC}"
  adb devices
  if adb devices | awk 'NR>1' | grep -q "$DEVICE_IP:$PORT"; then
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
  if [[ -n "$SCRCPY_ARGS" ]]; then
    # Parse scrcpy args safely
    nohup scrcpy -s "$DEVICE_IP:$PORT" $SCRCPY_ARGS >/dev/null 2>&1 &
  else
    nohup scrcpy -s "$DEVICE_IP:$PORT" >/dev/null 2>&1 &
  fi
  echo -e "${GREEN}[✓] scrcpy started (PID: $!)${NC}"
}

main() {
  print_banner
  check_adb

  adb start-server 2>/dev/null || true

  if detect_usb_device; then
    step_get_ip
    step_tcpip
    step_connect
    step_verify_wireless
    step_disconnect_usb_prompt
  else
    echo -e "${YELLOW}[!] No USB device detected.${NC}"
    read -rp "  Would you like to connect via Android 11+ Wireless Pairing mode? [Y/n]: " choice </dev/tty || choice="y"
    if [[ "$choice" =~ ^[Yy]|^$ ]]; then
      handle_android11_pairing
      step_connect
      step_verify_wireless
    else
      echo -e "${YELLOW}Connect your phone via USB and re-run standard setup.${NC}"
      exit 1
    fi
  fi

  if check_scrcpy; then
    step_show_shortcuts
    step_launch_scrcpy
  fi

  echo ""
  echo -e "${GREEN}  Done! Enjoy wireless ADB.${NC}"
}

main
