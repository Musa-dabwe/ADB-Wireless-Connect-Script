# ADB Wireless Connect Script

Automate connecting your Android phone to ADB over a wireless connection, with a separate script for `scrcpy` screen mirroring.

## 🌟 Features

- **Automated USB Setup**: Automatically detects USB-tethered phone, switches device to TCP/IP mode (`adb tcpip 5555` or custom port), extracts IP address, and connects wirelessly.
- **Android 11+ Wire-Free Pairing**: Pair over Wi-Fi using Android 11+ `adb pair` when no USB cable is available.
- **Reverse AP Mode (`reverse-ap.sh`)**: When the phone *is* the Wi-Fi hotspot and USB is unavailable, the laptop becomes the AP, the phone joins as a client, and wireless debugging works normally (mDNS discovery, no tether firewall, no cellular-NAT IP confusion).
- **Smart Dynamic IP Detection**: Prefers Wi-Fi/hotspot interfaces (`wlan0`, `wlan1`, `ap0`, …), skips cellular/carrier-NAT IPs that are unreachable from your PC, and pings candidates to confirm reachability. If ICMP is blocked or ping fails, falls back to the first suitable Wi-Fi address.
- **Multi-Device Selector**: Displays an interactive menu if multiple USB devices are attached. Garbage or out-of-range input falls back to the first device instead of the wrong one.
- **scrcpy Launcher (`scrcpy.sh`)**: Standalone script with interactive resolution and FPS selection menus. Works with USB and wireless devices. Tracks the session through a PID file, bounds the log directory, and can run in the foreground with `--wait` so a mid-session crash is visible.
- **Dedicated Cleanup (`stop.sh`)**: Interactive or non-interactive wireless session disconnect and ADB server restart tool. Every wireless target is labelled with its real adb state, and a partial disconnect is never reported as success.
- **CLI Options**: Supports non-interactive flags like `--port`, `--timeout`, `--wait`, `--force`, `--all`, and `--kill`.
- **Input validation**: `--port` is checked at both of its input paths before adb ever sees it, and the device pickers in both scripts fall back to the first device on bad input. A few adb calls are still unguarded. Six of them — `adb tcpip` and one `adb devices` dump in `start.sh`, plus `adb kill-server` / `adb start-server` in `stop.sh`'s two interactive restart branches — exit with adb's own error and no explanation from the script. A seventh, the second `adb devices` dump in `start.sh`, only prints adb's raw error before the correct diagnostic; it is cosmetic, not fatal. All seven are tracked as follow-ups in [`docs/BUILD.md`](docs/BUILD.md).

---

## 📋 Prerequisites

- An Android phone with:
  - **Developer Options** enabled
  - **USB Debugging** enabled (for Classic USB setup) OR **Wireless Debugging** enabled (for Android 11+ Pairing)
  - **Wi-Fi Hotspot** or **Wi-Fi** active
- A Linux machine (Debian, Ubuntu, Pop!_OS, Fedora, Arch)
- Optional: USB cable (for initial USB setup mode)
- For **Reverse AP mode** (`reverse-ap.sh`): `hostapd`, `dnsmasq`, `iw` (see Installation below)

---

## 🚀 Installation & Dependencies

### Clone Repository

```bash
git clone git@github.com:Musa-dabwe/ADB-Wireless-Connect-Script.git
cd ADB-Wireless-Connect-Script
chmod +x start.sh stop.sh scrcpy.sh reverse-ap.sh
```

### Install Dependencies

**ADB (Required)**

```bash
# Debian / Ubuntu / Pop!_OS
pkexec apt install adb

# Fedora / RHEL
pkexec dnf install android-tools

# Arch / Manjaro
pkexec pacman -S android-tools
```

**scrcpy (Optional — for Screen Mirroring)**

```bash
# Debian / Ubuntu / Pop!_OS
pkexec apt install scrcpy

# Fedora / RHEL
pkexec dnf install scrcpy

# Arch / Manjaro
pkexec pacman -S scrcpy
```

**Reverse AP Mode (Optional — for `reverse-ap.sh`)**

```bash
# Debian / Ubuntu / Pop!_OS
pkexec apt install hostapd dnsmasq iw network-manager adb

# Fedora / RHEL
pkexec dnf install hostapd dnsmasq iw NetworkManager android-tools

# Arch / Manjaro
pkexec pacman -S hostapd dnsmasq iw networkmanager android-tools
```

---

## 💡 Usage

### Starting Wireless Connection

```bash
./start.sh
```

#### CLI Options for `start.sh`:

```bash
./start.sh [options]

Options:
  -p, --port P          Specify target TCP port (default: 5555)
  -h, --help            Show this help message
```

The port is validated at **both** places it can be set — the `--port` flag and
the connect-port prompt in the Android 11+ pairing flow — and must be a number
between 1024 and 65535. An invalid value is rejected with the offending value
named, before adb is called.

If the connect attempt and its one retry both fail, the script names the target
it tried, lists the usual causes, and exits 1 instead of stopping silently.

---

### Launching Screen Mirroring (scrcpy)

Works with any connected device — USB or wireless. Plug in a phone and run it
directly, or connect wirelessly first and run it after:

```bash
./scrcpy.sh
```

The script will:
1. Detect connected ADB devices (USB, wireless, and emulators)
2. Prompt you to pick one if several are connected
3. Prompt you to select resolution (1280/800/640/Original)
4. Prompt you to select frame rate (60/30/Default)
5. Show keyboard shortcuts and launch scrcpy

If a device shows up as `unauthorized` or `offline`, the script names it and
prints the matching fix (accept the USB debugging prompt, or replug the cable)
instead of reporting that no device was found. The success line reports the
detected scrcpy version, e.g. `[✓] scrcpy detected (version 4.1)`.

`-s` / `--serial` must come before `-a` / `--args`, and `-a` may only be given
once — everything after it is forwarded to scrcpy verbatim, so a second `-a`
would silently reach scrcpy as an unknown option.

#### CLI Options for `scrcpy.sh`:

```bash
./scrcpy.sh [options]

Options:
  -a, --args ...      Pass custom arguments to scrcpy (must be final option)
  -s, --serial S      Specify device serial (USB id or ip:port)
  -t, --timeout S     Startup grace period in seconds (default: 2)
  -w, --wait          Run in the foreground and exit with scrcpy's status
  -f, --force         Kill a scrcpy session already running, then start a new one
  -h, --help          Show this help message
```

#### Session management

By default the launcher backgrounds scrcpy, waits the grace period to confirm it
survived startup, prints the log and PID file paths, and exits 0. Three flags
change that:

- `-t, --timeout S` — the startup grace period, replacing the previously
  hardcoded 1.25s. The default is 2 seconds. Fractional values are accepted
  (`--timeout 0.5`); non-numeric, negative, and zero values are rejected.
- `-w, --wait` — run scrcpy in the foreground, still redirected to its log,
  block until it exits, then remove the PID file and exit with **scrcpy's own
  exit status**. This is what makes a crash *after* a successful start visible
  in your terminal.
- `-f, --force` — stop a session that is already running, then start a new one.

The PID file is `${XDG_STATE_HOME:-$HOME/.local/state}/adb-wireless-connect/scrcpy.pid`.
If it names a live scrcpy, a second launch refuses and prints both the running
PID and the `kill` command to use. A PID file that does not positively identify
a running scrcpy (killed launcher, reboot, recycled PID) is treated as stale:
it is overwritten, and never blocks a launch or signals a stranger's process.
Identification is positional — the command line has to *be* scrcpy, reached by
stepping over any interpreter in front of it (`env bash …/scrcpy`). A process
that merely mentions scrcpy as an argument, such as `find / -name scrcpy` or
`vim scrcpy`, is not a session and is never signalled. `--force` escalates from
`SIGTERM` to `SIGKILL` after about a second, re-checking identity before the
`SIGKILL`: if the PID is no longer scrcpy by then, the launch stops and hands
the PID back to you instead of killing whatever holds it.

`stop.sh` disconnects ADB targets; it does **not** stop a scrcpy session. The two
are independent, so tearing down your ADB connection leaves the mirroring window
running. Stop it yourself with the `kill <pid>` printed on launch, or from the
PID file above.

The log directory is the same `adb-wireless-connect` directory, and holds one
`scrcpy.*.log` per launch alongside `scrcpy.pid`. Pruning keeps the newest 10
logs and always keeps the current launch's log, which is excluded from that count
rather than competing with it — so the directory holds at most 11 logs plus the
PID file. Pruning runs on the failure path too, since a device that will not
start is exactly when a user retries.

---

### Stopping / Cleaning Up Wireless Connection

```bash
./stop.sh
```

#### CLI Options for `stop.sh`:

```bash
./stop.sh [options]

Options:
  -a, --all     Disconnect all wireless ADB connections immediately
  -k, --kill    Kill the ADB server completely (adb kill-server)
  -h, --help    Show this help message
```

`adb devices` is read once per run, and both the target list and the per-target
state labels come from that one snapshot — so the listing can never contradict
itself. Each entry is labelled with the state adb actually reports, not assumed
to be active:

```text
[*] Wireless ADB targets:
    • 192.168.1.50:5555 (offline)
    • 192.168.1.51:5555 (no permissions (user in plugdev group); see [...])
```

Stale targets are still offered for `adb disconnect`, which is a legitimate
cleanup. Every target is attempted even if an earlier one fails — adb returns
non-zero for a target it has already dropped — and the run exits non-zero if any
target failed, with the success line suppressed so a partial cleanup is never
reported as complete.

---

### Reverse AP Mode (Phone is the Hotspot)

When the phone provides the Wi-Fi hotspot and no USB cable is available, wireless debugging fails because Android's adbd binds to the Wi-Fi *client* interface (which doesn't exist) and the tether firewall blocks traffic from hotspot clients back to the phone. The reverse AP script flips the topology: the laptop becomes the AP, the phone joins as an ordinary client, and wireless debugging then works normally.

```bash
./reverse-ap.sh start
```

On the phone: join the printed SSID (default `adbnet`), enable **Wireless debugging**, then either:
- Tap **Pair device with pairing code** and note the port + 6-digit code, OR
- Tap **Pair device with QR code** and save the QR code image

```bash
# Manual pairing
./reverse-ap.sh pair <pairing-port> <code>

# Or scan QR code image (PNG/JPG)
./reverse-ap.sh pair-qr ~/Pictures/pairing_qr.png

# Then connect
./reverse-ap.sh connect
```

Optional — also get internet through the phone's hotspot while keeping the AP up (uses a second virtual interface on the same channel):

```bash
./reverse-ap.sh internet "Oppo 1"
```

Check status or tear it down:

```bash
./reverse-ap.sh status
./reverse-ap.sh stop
```

#### CLI Options for `reverse-ap.sh`:

```bash
./reverse-ap.sh [options] <command> [args]

Commands:
  start                     Start the AP + DHCP and print next steps
  stop                      Tear the AP down and give the Wi-Fi back to NM
  status                    Show AP, clients, leases and adb state
  pair PORT CODE            Pair adb using the phone's DHCP IP and pairing port
  pair-qr IMAGE_FILE        Pair adb by scanning a QR code image (from "Pair with QR code")
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
```

**Key problems it solves:**

| Problem | Fix |
|---------|-----|
| Phone is the hotspot → no client interface for adbd | Laptop becomes AP, phone joins as client |
| wpa_supplicant can't start AP on Intel cards | Uses `hostapd` directly |
| UFW `INPUT DROP` eats DHCP DISCOVER → "connecting" forever | Opens udp/67 + subnet on the AP interface |
| Wireless debugging screen shows cellular IP (unreachable) | `pair`/`connect` use the DHCP lease IP automatically |
| Want internet AND adb | `internet` command adds a `sta0` vif on the same channel |

**Dependencies** (in addition to `adb`):
- `hostapd`, `dnsmasq`, `iw`, `ip`, `nmcli`
- `zbar` (for QR code pairing: `zbarimg`)

```bash
# Arch
pkexec pacman -S hostapd dnsmasq iw networkmanager android-tools zbar

# Debian / Ubuntu
pkexec apt install hostapd dnsmasq iw network-manager adb zbar-tools
```

---

## 🧪 Tests

Both suites are pure Bash and shadow the tools each one drives with mock binaries
on `PATH`, driven by `MOCK_*` environment variables: the launcher suite mocks
`adb` and `scrcpy`, and the `start.sh` / `stop.sh` suite mocks `adb`, `ping`, and
`sleep`. No case contacts a real device, and no case leaves a process running.

```bash
bash tests/test_scrcpy_launcher.sh   # scrcpy.sh
bash tests/test_start_stop.sh        # start.sh and stop.sh
```

Each suite prints one `PASS:` line per case group (4 groups for the launcher, 5
for `start.sh` / `stop.sh`) and exits non-zero on the first failed assertion. A
handful of cases need a pty to answer a `/dev/tty` prompt; they use util-linux
`script` and print a visible `SKIP:` line when it is not installed, rather than
silently passing as the default-answer path.

---

## ⌨️ scrcpy Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Alt + H` | Home |
| `Alt + B` | Back |
| `Alt + S` | Switch apps |
| `alt + F` | Toggle fullscreen |
| `Alt + O` | Turn phone screen off |
| `Alt + P` | Power button |
| `Alt + Up` | Volume up |
| `Alt + Down` | Volume down |

---

## 📄 License

[MIT](LICENSE.md)