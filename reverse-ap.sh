#!/usr/bin/env bash
# reverse-ap.sh — wireless ADB when the *phone* is the Wi-Fi hotspot.
#
# The problem this solves
# -----------------------
# Android's wireless-debugging adbd binds to the Wi-Fi *client* interface. When
# the phone is the hotspot there is no client interface, so adb cannot reach it,
# and mDNS discovery (adb mdns services) does not cross the AP boundary. The
# tether firewall also drops traffic from hotspot clients back to the phone.
#
# The workaround: reverse the topology. The laptop becomes the AP, the phone
# joins it as an ordinary Wi-Fi client, and wireless debugging then behaves
# normally (adbd binds to wlan0, mDNS works, no tether firewall in the path).
#
# Two gotchas are handled explicitly here:
#   1. A firewall with `INPUT DROP` (ufw, firewalld) silently eats the phone's
#      DHCP DISCOVER, so the phone sits on "connecting" forever. Port 67/udp and
#      the AP subnet are opened on the AP interface.
#   2. The phone's Wireless debugging screen shows its *cellular* IP (carrier
#      NAT, unreachable). `pair` and `connect` use the DHCP lease IP instead.
#
# hostapd is used directly instead of NetworkManager's hotspot mode: on some
# Wi-Fi cards wpa_supplicant cannot start AP mode ("key setting validation
# failed"), while hostapd can.
#
# Privileges: start/stop/status/internet need root and re-exec through pkexec.
# pair/connect are unprivileged.
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

STATE_DIR=/run/adb-reverse-ap

IFACE=""
SSID=adbnet
PASSWORD=""
SUBNET=10.42.0.0/24
CHANNEL=6
NO_FIREWALL=false

CMD=""
POSITIONAL=()

ORIG_ARGS=("$@")

log()  { echo -e "${YELLOW}[*] $*${NC}"; }
ok()   { echo -e "${GREEN}[✓] $*${NC}"; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }
die()  { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }

usage() {
  cat <<'EOF'
ADB Wireless Connect — reverse AP mode

Connect adb when the phone itself is the Wi-Fi hotspot (no working USB needed).

Usage: ./reverse-ap.sh [options] <command> [args]

Commands:
  start                     Start the AP + DHCP and print next steps
  stop                      Tear the AP down and give the Wi-Fi back to NM
  status                    Show AP, clients, leases and adb state
  pair PORT CODE            Pair adb using the phone's DHCP IP and pairing port
  pair-qr IMAGE_FILE        Pair adb by scanning a QR code image (from "Pair with QR code")
  pair-qr-cam [DEVICE]      Pair adb by scanning QR code from laptop camera
  connect [PORT]            Connect adb (PORT omitted: use mDNS discovery)
  internet SSID [PASSWORD]  Also join a hotspot for internet, keeping the AP up

Options:
  -i, --iface IFACE         Wi-Fi interface (default: auto-detect)
  -s, --ssid SSID           AP SSID (default: adbnet)
  -w, --password PASS       WPA2 passphrase (default: open network)
  -n, --subnet CIDR         AP subnet, /24 (default: 10.42.0.0/24)
  -c, --channel N           AP channel (default: 6)
      --no-firewall         Do not touch ufw
  -h, --help                Show this help

Examples:
  ./reverse-ap.sh start
  ./reverse-ap.sh pair 37357 671790
  ./reverse-ap.sh pair-qr ~/Pictures/qr.png
  ./reverse-ap.sh pair-qr-cam
  ./reverse-ap.sh pair-qr-cam /dev/video0
  ./reverse-ap.sh connect
  ./reverse-ap.sh internet "Oppo 1"
  ./reverse-ap.sh stop
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--iface)    [[ $# -ge 2 ]] || die "Option $1 needs an interface"; IFACE="$2"; shift 2 ;;
    -s|--ssid)     [[ $# -ge 2 ]] || die "Option $1 needs an SSID"; SSID="$2"; shift 2 ;;
    -w|--password) [[ $# -ge 2 ]] || die "Option $1 needs a passphrase"; PASSWORD="$2"; shift 2 ;;
    -n|--subnet)   [[ $# -ge 2 ]] || die "Option $1 needs a CIDR"; SUBNET="$2"; shift 2 ;;
    -c|--channel)  [[ $# -ge 2 ]] || die "Option $1 needs a channel"; CHANNEL="$2"; shift 2 ;;
    --no-firewall) NO_FIREWALL=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "Unknown option: $1" ;;
    *)             CMD="$1"; shift; break ;;
  esac
done
POSITIONAL=("$@")

if [[ -z "$CMD" ]]; then
  usage
  exit 1
fi

require_root() {
  [[ $EUID -eq 0 ]] && return 0
  command -v pkexec >/dev/null 2>&1 || \
    die "This action needs root. Run: sudo $0 $CMD"
  exec pkexec --user root "$(readlink -f "$0")" "${ORIG_ARGS[@]}"
}

# ---------------------------------------------------------------- helpers ----

detect_iface() {
  if [[ -n "$IFACE" ]]; then
    iw dev "$IFACE" info >/dev/null 2>&1 || die "Interface $IFACE is not a wireless device"
    return 0
  fi
  # Prefer a physical Wi-Fi device. Skip the secondary client vif this script
  # creates (sta0) and NetworkManager's p2p-device, which also report type wifi.
  IFACE=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
    | awk -F: '$2=="wifi" && $1 !~ /^(sta|p2p)/ {print $1; exit}')
  if [[ -z "$IFACE" ]]; then
    IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
  fi
  [[ -n "$IFACE" ]] || die "No wireless interface found (use --iface)"
}

check_deps() {
  local missing=()
  local cmd
  for cmd in hostapd dnsmasq iw ip adb nmcli; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing: ${missing[*]}"
    echo "  Arch:   pkexec pacman -S hostapd dnsmasq iw networkmanager android-tools"
    echo "  Debian: pkexec apt install hostapd dnsmasq iw network-manager adb"
    exit 1
  fi
}

validate_subnet() {
  [[ "$SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/24$ ]] \
    || die "Subnet must be an IPv4 /24 network, e.g. 10.42.0.0/24"
  [[ "$CHANNEL" =~ ^[0-9]{1,3}$ ]] || die "Channel must be a number"
  (( CHANNEL >= 1 && CHANNEL <= 165 )) || die "Channel must be between 1 and 165"
}

ap_ip()     { local base="${SUBNET%/*}"; printf '%s.1\n' "${base%.*}"; }
ap_cidr()   { printf '%s\n' "$SUBNET"; }
dhcp_range() {
  local base="${SUBNET%/*}"
  printf '%s.10,%s.100\n' "${base%.*}" "${base%.*}"
}

hostapd_pid()  { cat "$STATE_DIR/hostapd.pid" 2>/dev/null || true; }
dnsmasq_pid()  { cat "$STATE_DIR/dnsmasq.pid" 2>/dev/null || true; }

is_running() {
  local pid
  pid=$(hostapd_pid)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

first_lease_ip() {
  local leases="$STATE_DIR/dnsmasq.leases"
  [[ -f "$leases" ]] || return 1
  awk '$3 ~ /^[0-9]+\./ {print $3; exit}' "$leases"
}

write_hostapd_conf() {
  local conf="$STATE_DIR/hostapd.conf"
  # 2.4 GHz channels use hw_mode=g; 5 GHz channels use hw_mode=a.
  local hw_mode=g
  (( CHANNEL > 14 )) && hw_mode=a
  {
    echo "interface=$IFACE"
    echo "driver=nl80211"
    echo "ssid=$SSID"
    echo "hw_mode=$hw_mode"
    echo "channel=$CHANNEL"
    echo "beacon_int=100"
    echo "auth_algs=1"
    echo "wmm_enabled=1"
    echo "ignore_broadcast_ssid=0"
    if [[ -n "$PASSWORD" ]]; then
      echo "wpa=2"
      echo "wpa_passphrase=$PASSWORD"
      echo "wpa_key_mgmt=WPA-PSK"
      echo "rsn_pairwise=CCMP"
    fi
  } > "$conf"
}

start_hostapd() {
  write_hostapd_conf
  hostapd "$STATE_DIR/hostapd.conf" > "$STATE_DIR/hostapd.log" 2>&1 &
  echo $! > "$STATE_DIR/hostapd.pid"

  local i
  for i in $(seq 1 20); do
    if iw dev "$IFACE" info 2>/dev/null | grep -q "type AP"; then
      return 0
    fi
    sleep 0.5
  done
  warn "hostapd did not reach AP mode. Log: $STATE_DIR/hostapd.log"
  tail -5 "$STATE_DIR/hostapd.log" >&2 || true
  return 1
}

stop_hostapd() {
  local pid
  pid=$(hostapd_pid)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 10); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$STATE_DIR/hostapd.pid"
}

start_dnsmasq() {
  dnsmasq \
    --interface="$IFACE" \
    --bind-interfaces \
    --dhcp-range="$(dhcp_range),12h" \
    --no-resolv --no-hosts \
    --log-dhcp \
    --pid-file="$STATE_DIR/dnsmasq.pid" \
    --dhcp-leasefile="$STATE_DIR/dnsmasq.leases" \
    > "$STATE_DIR/dnsmasq.log" 2>&1 &
  echo $! > "$STATE_DIR/dnsmasq.pid"
  sleep 0.5
  if ! kill -0 "$(cat "$STATE_DIR/dnsmasq.pid")" 2>/dev/null; then
    warn "dnsmasq failed to start. Log: $STATE_DIR/dnsmasq.log"
    tail -5 "$STATE_DIR/dnsmasq.log" >&2 || true
    return 1
  fi
}

stop_dnsmasq() {
  local pid
  pid=$(dnsmasq_pid)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$STATE_DIR/dnsmasq.pid"
}

open_firewall() {
  if $NO_FIREWALL; then
    return 0
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    # The phone has no IP yet, so a subnet-scoped rule cannot match its DHCP
    # DISCOVER. Port 67 must be opened independently of the source address.
    ufw allow in on "$IFACE" to any port 67 proto udp >/dev/null 2>&1 || true
    ufw allow in on "$IFACE" from "$(ap_cidr)" >/dev/null 2>&1 || true
    ok "ufw: allowed DHCP (67/udp) and $(ap_cidr) on $IFACE"
  else
    warn "No active ufw detected — make sure DHCP (udp/67) and $(ap_cidr) are allowed on $IFACE"
  fi
}

close_firewall() {
  if $NO_FIREWALL; then
    return 0
  fi
  command -v ufw >/dev/null 2>&1 || return 0
  ufw delete allow in on "$IFACE" to any port 67 proto udp >/dev/null 2>&1 || true
  ufw delete allow in on "$IFACE" from "$(ap_cidr)" >/dev/null 2>&1 || true
}

sta_iface() { echo "sta0"; }

stop_sta() {
  local sta
  sta=$(sta_iface)
  # Never delete the interface the AP is running on.
  [[ -n "${IFACE:-}" && "$sta" == "$IFACE" ]] && return 0
  if iw dev "$sta" info >/dev/null 2>&1; then
    nmcli device disconnect "$sta" >/dev/null 2>&1 || true
    nmcli connection delete "reverse-ap-internet" >/dev/null 2>&1 || true
    iw dev "$sta" del >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------- commands ---

cmd_start() {
  require_root
  check_deps
  detect_iface
  validate_subnet

  if is_running; then
    ok "AP already running on $IFACE ($SSID, $(ap_ip))"
    return 0
  fi

  mkdir -p "$STATE_DIR"
  echo "$IFACE" > "$STATE_DIR/iface"
  echo "$SUBNET" > "$STATE_DIR/subnet"
  echo "$SSID" > "$STATE_DIR/ssid"

  log "Taking $IFACE away from NetworkManager..."
  nmcli device set "$IFACE" managed no >/dev/null 2>&1 || true
  ip link set "$IFACE" down

  log "Starting hostapd on $IFACE (channel $CHANNEL)..."
  start_hostapd || { teardown; exit 1; }

  ip addr flush dev "$IFACE" >/dev/null 2>&1 || true
  ip addr add "$(ap_ip)/24" dev "$IFACE"
  ip link set "$IFACE" up

  log "Starting DHCP server ($(dhcp_range))..."
  start_dnsmasq || { teardown; exit 1; }

  open_firewall

  echo ""
  ok "AP up: SSID \"$SSID\", $(ap_ip)/24 on $IFACE"
  [[ -z "$PASSWORD" ]] && warn "The AP is open (no WPA2). adb is still protected by the paired RSA key."
  echo ""
  echo -e "${CYAN}  On the phone:${NC}"
  echo "    1. Turn off its own hotspot."
  echo "    2. Wi-Fi → join \"$SSID\"$([[ -n "$PASSWORD" ]] && echo " (password: $PASSWORD)")"
  echo "       If Android says \"no internet\", choose Stay connected."
  echo "    3. Developer options → Wireless debugging → ON."
  echo "    4. Tap \"Pair device with pairing code\" and note the port + code."
  echo ""
  echo -e "${CYAN}  Then here:${NC}"
  echo "    ./reverse-ap.sh pair <pairing-port> <code>"
  echo "    ./reverse-ap.sh connect"
  echo ""
}

cmd_stop() {
  require_root
  if [[ ! -d "$STATE_DIR" ]]; then
    warn "AP is not running."
    return 0
  fi
  local iface
  iface=$(cat "$STATE_DIR/iface" 2>/dev/null || true)
  [[ -n "$iface" ]] && IFACE="$iface"

  log "Stopping AP..."
  stop_sta
  stop_hostapd
  stop_dnsmasq

  if [[ -n "$iface" ]]; then
    ip addr flush dev "$iface" >/dev/null 2>&1 || true
    ip link set "$iface" up >/dev/null 2>&1 || true
    nmcli device set "$iface" managed yes >/dev/null 2>&1 || true
    close_firewall
  fi

  rm -rf "$STATE_DIR"
  ok "AP stopped; $iface returned to NetworkManager."
  echo "  adb connections are left alone — run ./stop.sh to clear them."
}

teardown() {
  stop_sta
  stop_hostapd
  stop_dnsmasq
  local iface
  iface=$(cat "$STATE_DIR/iface" 2>/dev/null || true)
  if [[ -n "$iface" ]]; then
    ip addr flush dev "$iface" >/dev/null 2>&1 || true
    nmcli device set "$iface" managed yes >/dev/null 2>&1 || true
  fi
  rm -rf "$STATE_DIR"
}

cmd_status() {
  require_root
  local iface
  iface=$(cat "$STATE_DIR/iface" 2>/dev/null || true)
  [[ -n "$iface" ]] && IFACE="$iface"

  if ! is_running; then
    warn "AP is not running."
    return 1
  fi

  echo -e "${CYAN}AP${NC}"
  iw dev "$IFACE" info 2>/dev/null | grep -E "ssid|type|channel" | sed 's/^/    /'
  echo "    address: $(ip -4 -brief addr show "$IFACE" | awk '{print $3}')"

  echo -e "${CYAN}Clients${NC}"
  local stations
  stations=$(iw dev "$IFACE" station dump 2>/dev/null | awk '/Station/{print "    " $2}' || true)
  [[ -n "$stations" ]] && echo "$stations" || echo "    (none associated)"

  echo -e "${CYAN}DHCP leases${NC}"
  if [[ -s "$STATE_DIR/dnsmasq.leases" ]]; then
    awk '{printf "    %s  %s  %s\n", $3, $2, $4}' "$STATE_DIR/dnsmasq.leases"
  else
    echo "    (no leases yet)"
  fi

  echo -e "${CYAN}Internet uplink${NC}"
  if iw dev "$(sta_iface)" info >/dev/null 2>&1; then
    echo "    $(sta_iface): $(ip -4 -brief addr show "$(sta_iface)" | awk '{print $3}')"
  else
    echo "    (not configured — run: ./reverse-ap.sh internet <SSID>)"
  fi

  echo -e "${CYAN}adb${NC}"
  adb devices | sed 's/^/    /'
}

cmd_pair() {
  local port="${POSITIONAL[0]:-}" code="${POSITIONAL[1]:-}"
  [[ -n "$port" && -n "$code" ]] || die "Usage: ./reverse-ap.sh pair <pairing-port> <6-digit-code>"

  local ip
  ip=$(first_lease_ip) || die "No DHCP lease found — is the phone connected to the AP? (./reverse-ap.sh status)"
  warn "The phone's Wireless debugging screen shows its cellular IP; using the DHCP lease IP instead: $ip"
  log "Pairing $ip:$port ..."
  local out
  out=$(timeout 30 adb pair "$ip:$port" "$code" 2>&1 || true)
  echo "    $out"
  if ! echo "$out" | grep -qi "successfully paired"; then
    die "Pairing failed. Check the port/code and that Wireless debugging is on."
  fi
  ok "Paired. Now run: ./reverse-ap.sh connect"
}

cmd_pair_qr() {
  local image_file="${POSITIONAL[0]:-}"
  [[ -n "$image_file" ]] || die "Usage: ./reverse-ap.sh pair-qr <image-file>"
  [[ -f "$image_file" ]] || die "File not found: $image_file"

  _scan_and_pair_from_image "$image_file"
}

_scan_qr_from_image() {
  local image_file="$1"
  command -v zbarimg >/dev/null 2>&1 || die "zbarimg not found. Install: pkexec pacman -S zbar (Arch) / pkexec apt install zbar-tools (Debian)"
  zbarimg --quiet "$image_file" 2>/dev/null | head -1 | sed 's/^[^:]*: *//'
}

_parse_qr_data() {
  local qr_data="$1"
  local ip port code

  if [[ "$qr_data" =~ ^adb://([^@]+)@([^:]+):([0-9]+)$ ]]; then
    code="${BASH_REMATCH[1]}"
    ip="${BASH_REMATCH[2]}"
    port="${BASH_REMATCH[3]}"
  elif [[ "$qr_data" =~ ^([^:]+):([0-9]+):([0-9]{6})$ ]]; then
    ip="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    code="${BASH_REMATCH[3]}"
  elif [[ "$qr_data" == "WIFI:T:ADB;S:"* ]]; then
    die "WIFI config QR format not supported for pairing. Use 'Pair device with pairing code' QR instead."
  else
    die "Unrecognized QR code format: $qr_data"
  fi
  printf '%s\n%s\n%s\n' "$ip" "$port" "$code"
}

_pair_with_parsed_qr() {
  local ip="$1" port="$2" code="$3"

  # Use DHCP lease IP instead of the IP in QR (which is often cellular)
  local lease_ip
  lease_ip=$(first_lease_ip) || die "No DHCP lease found — is the phone connected to the AP?"
  warn "QR code contains IP $ip; using DHCP lease IP instead: $lease_ip"
  ip="$lease_ip"

  log "Pairing $ip:$port with code $code ..."
  local out
  out=$(timeout 30 adb pair "$ip:$port" "$code" 2>&1 || true)
  echo "    $out"
  if ! echo "$out" | grep -qi "successfully paired"; then
    die "Pairing failed. Check that Wireless debugging is on and the QR code is fresh."
  fi
  ok "Paired via QR code. Now run: ./reverse-ap.sh connect"
}

_scan_and_pair_from_image() {
  local image_file="$1"
  log "Scanning QR code from $image_file ..."
  local qr_data
  qr_data=$(_scan_qr_from_image "$image_file")
  [[ -n "$qr_data" ]] || die "No QR code found in image"
  log "QR data: $qr_data"

  local parsed
  parsed=$(_parse_qr_data "$qr_data")
  local ip port code
  ip=$(echo "$parsed" | sed -n '1p')
  port=$(echo "$parsed" | sed -n '2p')
  code=$(echo "$parsed" | sed -n '3p')

  _pair_with_parsed_qr "$ip" "$port" "$code"
}

cmd_pair_qr_cam() {
  local device="${POSITIONAL[0]:-}"
  local max_attempts=10
  local attempt=1

  command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found for camera capture"
  command -v zbarimg >/dev/null 2>&1 || die "zbarimg not found. Install: pkexec pacman -S zbar (Arch) / pkexec apt install zbar-tools (Debian)"

  # Auto-detect video device if not specified
  if [[ -z "$device" ]]; then
    device=$(v4l2-ctl --list-devices 2>/dev/null | awk '/video[0-9]+/{print $NF; exit}')
    [[ -n "$device" ]] || die "No video device found. Specify with: ./reverse-ap.sh pair-qr-cam /dev/video0"
    log "Auto-detected camera: $device"
  fi
  [[ -e "$device" ]] || die "Video device not found: $device"

  echo -e "${CYAN}Point your phone's QR code at the camera. Press Ctrl+C to cancel.${NC}"
  echo ""

  local temp_img="/tmp/adb_qr_cam_$$.png"

  while (( attempt <= max_attempts )); do
    log "Attempt $attempt/$max_attempts: capturing frame from $device ..."
    
    # Capture a single frame
    if ffmpeg -loglevel error -f v4l2 -i "$device" -vframes 1 -y "$temp_img" 2>/dev/null; then
      local qr_data
      qr_data=$(_scan_qr_from_image "$temp_img")
      
      if [[ -n "$qr_data" ]]; then
        log "QR data: $qr_data"
        local parsed
        parsed=$(_parse_qr_data "$qr_data")
        local ip port code
        ip=$(echo "$parsed" | sed -n '1p')
        port=$(echo "$parsed" | sed -n '2p')
        code=$(echo "$parsed" | sed -n '3p')
        rm -f "$temp_img"
        _pair_with_parsed_qr "$ip" "$port" "$code"
        return 0
      else
        warn "No QR code detected in frame"
      fi
    else
      warn "Failed to capture frame from camera"
    fi

    ((attempt++))
    [[ $attempt -le $max_attempts ]] && sleep 1
  done

  rm -f "$temp_img"
  die "QR code not detected after $max_attempts attempts. Make sure the QR code is visible and well-lit."
}

cmd_connect() {
  local port="${POSITIONAL[0]:-}"
  local ip addr

  if [[ -n "$port" ]]; then
    ip=$(first_lease_ip) || die "No DHCP lease found — is the phone connected to the AP?"
    addr="$ip:$port"
    log "Connecting to $addr ..."
    timeout 20 adb connect "$addr" || true
  else
    log "Looking for the paired device over mDNS..."
    addr=$(adb mdns services 2>/dev/null | awk '/_adb-tls-connect\._tcp/{print $NF; exit}' || true)
    if [[ -n "$addr" ]]; then
      log "Connecting to $addr ..."
      timeout 20 adb connect "$addr" || true
    else
      warn "No mDNS service found. Pass the port explicitly: ./reverse-ap.sh connect <port>"
    fi
  fi

  sleep 2
  if adb devices | awk 'NR>1 && $2=="device"{found=1} END{exit !found}'; then
    ok "adb device ready:"
    adb devices | sed 's/^/    /'
  else
    warn "No ready adb device yet. Check ./reverse-ap.sh status and the phone's Wireless debugging screen."
  fi
}

cmd_internet() {
  require_root
  local ssid="${POSITIONAL[0]:-}"
  local pass="${POSITIONAL[1]:-}"
  [[ -n "$ssid" ]] || die "Usage: ./reverse-ap.sh internet <hotspot-SSID> [password]"

  local iface sta
  iface=$(cat "$STATE_DIR/iface" 2>/dev/null || true)
  [[ -n "$iface" ]] && IFACE="$iface"
  is_running || die "Start the AP first: ./reverse-ap.sh start"
  sta=$(sta_iface)

  # The card allows one AP + one client on the SAME channel. Stop the AP first,
  # join the hotspot (any channel), then bring the AP back up on that channel.
  log "Pausing the AP to learn the hotspot's channel..."
  stop_hostapd

  if ! iw dev "$sta" info >/dev/null 2>&1; then
    iw dev "$IFACE" interface add "$sta" type managed
    ip link set "$sta" up
    nmcli device set "$sta" managed yes >/dev/null 2>&1 || true
  fi

  if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$ssid"; then
    log "Joining saved hotspot \"$ssid\" on $sta ..."
    nmcli connection up "$ssid" ifname "$sta" >/dev/null
  else
    [[ -n "$pass" ]] || die "No saved profile for \"$ssid\" — pass the password: ./reverse-ap.sh internet \"$ssid\" <password>"
    log "Joining hotspot \"$ssid\" on $sta ..."
    nmcli connection add type wifi ifname "$sta" con-name reverse-ap-internet \
      ssid "$ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass" >/dev/null
    nmcli connection up reverse-ap-internet ifname "$sta" >/dev/null
  fi

  local i
  for i in $(seq 1 20); do
    ip -4 -brief addr show "$sta" | grep -q "inet " && break
    sleep 0.5
  done
  ip -4 -brief addr show "$sta" | grep -q "inet " || die "Hotspot join failed (no IP on $sta)."

  local hotspot_ch
  hotspot_ch=$(iw dev "$sta" info 2>/dev/null | awk '/channel/{print $2; exit}')
  log "Hotspot is on channel ${hotspot_ch:-?}; restarting the AP to match..."
  CHANNEL="${hotspot_ch:-$CHANNEL}"
  start_hostapd || die "Could not restart the AP on channel $CHANNEL"

  echo ""
  ok "Internet via $sta, AP back up on channel $CHANNEL"
  echo "    $(ip -4 -brief addr show "$sta" | awk '{print "uplink: " $3}')"
  ip route | grep '^default' | sed 's/^/    /'
  echo ""
  echo "  The phone should rejoin \"$SSID\" automatically and adb will come back"
  echo "  over mDNS. Verify with: ./reverse-ap.sh status"
}

case "$CMD" in
  start)        cmd_start ;;
  stop)         cmd_stop ;;
  status)       cmd_status ;;
  pair)         cmd_pair ;;
  pair-qr)      cmd_pair_qr ;;
  pair-qr-cam)  cmd_pair_qr_cam ;;
  connect)      cmd_connect ;;
  internet)     cmd_internet ;;
  help|-h|--help) usage ;;
  *) die "Unknown command: $CMD (try --help)" ;;
esac
