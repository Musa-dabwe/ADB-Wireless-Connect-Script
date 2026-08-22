#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PORT=5555

show_help() {
  echo -e "${CYAN}ADB Wireless Connect - start.sh${NC}"
  echo ""
  echo "Usage: ./start.sh [options]"
  echo ""
  echo "Options:"
  echo "  -p, --port P          Specify target TCP port (default: 5555)"
  echo "  -h, --help            Show this help message"
  echo ""
}

# Parse CLI flags
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -p|--port)
      if [[ -z "$2" || "$2" =~ ^- ]]; then
        echo -e "${YELLOW}[!] Option $1 requires a port argument.${NC}"
        show_help
        exit 1
      fi
      PORT="$2"; shift 2 ;;
    -h|--help) show_help; exit 0 ;;
    *) echo -e "${YELLOW}[!] Unknown option: $1${NC}"; show_help; exit 1 ;;
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

detect_usb_device() {
  local devices
  mapfile -t devices < <(adb devices | awk 'NR>1 && $2=="device" && $1 !~ /:[0-9]+$/ {print $1}')
  
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
    local pair_out
    pair_out=$(timeout 30 adb pair "$pair_addr" "$pair_code" 2>&1 || true)
    echo "    $pair_out"
    if ! echo "$pair_out" | grep -qi "successfully paired"; then
      echo -e "${YELLOW}[!] Pairing failed. Check the IP, pairing port and code, then try again.${NC}"
      exit 1
    fi
    echo -e "${GREEN}[✓] Pairing successful!${NC}"
    echo ""
    read -rp "  Enter target Connect Port shown on main Wireless Debugging page [default: $PORT]: " target_port </dev/tty || target_port="$PORT"
    DEVICE_IP="${pair_addr%%:*}"
    PORT="${target_port:-$PORT}"
  else
    echo -e "${YELLOW}[!] Pairing details missing. Exiting.${NC}"
    exit 1
  fi
}

is_cgnat_ip() {
  # 100.64.0.0/10 (carrier-grade NAT) — never reachable from the LAN
  [[ "$1" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}

step_get_ip() {
  echo -e "${YELLOW}[*] Extracting device IP address...${NC}"
  local ip=""

  # NOTE: "ip route get 1.1.1.1" is unreliable — when mobile data is the
  # phone's default route it returns the cellular IP (behind carrier NAT),
  # which the PC can never reach. Enumerate interfaces and prefer Wi-Fi.
  # Output pairs: "<iface> <ipv4>" (e.g. "wlan1 192.168.139.208")
  local iface_ips
  iface_ips=$(adb -s "$DEVICE_ID" shell ip addr 2>/dev/null | awk '
    /^[0-9]+:/ {
      iface = $2
      sub(/@.*/, "", iface)  # strip peer suffix (rmnet_data1@rmnet_ipa0)
      sub(/:$/, "", iface)
    }
    /^[[:space:]]+inet / {
      split($2, a, "/")
      print iface, a[1]
    }' || true)

  local wifi_candidates=() other_candidates=()
  local iface addr
  while read -r iface addr; do
    [[ -z "$addr" ]] && continue
    case "$addr" in
      127.*|169.254.*) continue ;;  # loopback / link-local
    esac
    if is_cgnat_ip "$addr"; then
      continue
    fi
    case "$iface" in
      wlan*|ap*|swlan*|wlx*) wifi_candidates+=("$addr") ;;  # Wi-Fi / hotspot
      rmnet*|ccmni*|pdp*|wwan*) ;;                          # cellular — skip
      *) other_candidates+=("$addr") ;;
    esac
  done <<< "$iface_ips"

  # Pick the first candidate the PC can actually reach
  local candidate
  for candidate in "${wifi_candidates[@]}" "${other_candidates[@]}"; do
    [[ -z "$candidate" ]] && continue
    if ping -c1 -W1 "$candidate" &>/dev/null; then
      ip="$candidate"
      break
    fi
  done

  # Nothing pingable (ICMP may be blocked) — fall back to first Wi-Fi IP
  if [[ -z "$ip" && ${#wifi_candidates[@]} -gt 0 ]]; then
    ip="${wifi_candidates[0]}"
    echo -e "${YELLOW}[!] Could not ping $ip, but it is on a Wi-Fi interface; trying it anyway.${NC}"
  fi

  if [[ -z "$ip" ]]; then
    echo -e "${YELLOW}[!] Could not auto-detect a reachable Wi-Fi IP address.${NC}"
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
  # `timeout` guards against adb hanging on unreachable IPs (|| true: keep set -e calm)
  out=$(timeout 15 adb connect "$DEVICE_IP:$PORT" 2>&1 || true)
  echo "    $out"
  if echo "$out" | grep -qi "failed\|unable\|error" || [[ -z "$out" ]]; then
    echo -e "${YELLOW}[!] Connection failed. Retrying in 3 seconds...${NC}"
    sleep 3
    out=$(timeout 15 adb connect "$DEVICE_IP:$PORT" 2>&1 || true)
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
    return 0
  else
    echo ""
    echo -e "${YELLOW}  [!] Device not showing as connected wirelessly. Check the IP and try again.${NC}"
    return 1
  fi
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
    if ! step_disconnect_usb_prompt; then
      exit 1
    fi
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

  echo ""
  echo -e "${GREEN}  Done! Enjoy wireless ADB.${NC}"
  echo -e "${CYAN}  Run ./scrcpy.sh to launch screen mirroring.${NC}"
}

main
