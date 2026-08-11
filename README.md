# ADB Wireless Connect Script

Automate connecting your Android phone to ADB over a wireless connection and launch `scrcpy` for screen mirroring — with modular `start.sh` and `stop.sh` scripts.

## 🌟 Features

- **Automated USB Setup**: Automatically detects USB-tethered phone, switches device to TCP/IP mode (`adb tcpip 5555` or custom port), extracts IP address, and connects wirelessly.
- **Android 11+ Wire-Free Pairing**: Pair over Wi-Fi using Android 11+ `adb pair` when no USB cable is available.
- **Smart Dynamic IP Detection**: Prefers Wi-Fi/hotspot interfaces (`wlan0`, `wlan1`, `ap0`, …), skips cellular/carrier-NAT IPs that are unreachable from your PC, and pings candidates to confirm reachability before connecting.
- **Multi-Device Selector**: Displays an interactive menu if multiple USB devices are attached.
- **Screen Mirroring Integration**: Optionally launches `scrcpy` in the background with keyboard shortcut guidance.
- **Dedicated Cleanup (`stop.sh`)**: Interactive or non-interactive wireless session disconnect and ADB server restart tool.
- **CLI Options**: Supports non-interactive flags like `--no-scrcpy`, `--scrcpy-args`, `--port`, and `--all`.

---

## 📋 Prerequisites

- An Android phone with:
  - **Developer Options** enabled
  - **USB Debugging** enabled (for Classic USB setup) OR **Wireless Debugging** enabled (for Android 11+ Pairing)
  - **Wi-Fi Hotspot** or **Wi-Fi** active
- A Linux machine (Debian, Ubuntu, Pop!_OS, Fedora, Arch)
- Optional: USB cable (for initial USB setup mode)

---

## 🚀 Installation & Dependencies

### Clone Repository

```bash
git clone git@github.com:Musa-dabwe/ADB-Wireless-Connect-Script.git
cd ADB-Wireless-Connect-Script
chmod +x start.sh stop.sh
```

### Install Dependencies

**ADB (Required)**
```bash
# Debian / Ubuntu / Pop!_OS
sudo apt install adb

# Fedora / RHEL
sudo dnf install android-tools

# Arch / Manjaro
sudo pacman -S android-tools
```

**scrcpy (Optional — for Screen Mirroring)**
```bash
# Debian / Ubuntu / Pop!_OS (or use pkexec)
sudo apt install scrcpy

# Fedora / RHEL
sudo dnf install scrcpy

# Arch / Manjaro
sudo pacman -S scrcpy
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
  -n, --no-scrcpy       Skip launching scrcpy screen mirroring
  -a, --scrcpy-args S   Pass custom arguments to scrcpy (e.g. -a "--turn-screen-off --stay-awake")
  -p, --port P          Specify target TCP port (default: 5555)
  -h, --help            Show help message
```

---

### Stopping / Cleaning Up Wireless Connection

```bash
./stop.sh
```

#### CLI Options for `stop.sh`:
```bash
./stop.sh [options]

Options:
  -a, --all     Disconnect all active wireless ADB targets immediately
  -k, --kill    Kill the ADB server completely (adb kill-server)
  -h, --help    Show help message
```

---

## ⌨️ scrcpy Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Alt + H` | Home |
| `Alt + B` | Back |
| `Alt + S` | Switch apps |
| `Alt + F` | Toggle fullscreen |
| `Alt + O` | Turn phone screen off |
| `Alt + P` | Power button |
| `Alt + Up` | Volume up |
| `Alt + Down` | Volume down |

---

## 📄 License

[MIT](LICENSE.md)
