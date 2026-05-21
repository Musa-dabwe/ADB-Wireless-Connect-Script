# ADB Wireless Connect Script

Automate connecting your Android phone to ADB over a wireless (mobile data) connection and launch scrcpy for screen mirroring — all with a single script.

## Overview

This script walks you through every step of setting up a wireless ADB connection. It verifies dependencies, detects your phone via USB, extracts the mobile data IP address (`rmnet_data0`), switches the device to TCP/IP mode, connects wirelessly, confirms the connection, and optionally launches scrcpy with keyboard shortcut guidance.

No manual IP lookups. No typing `adb connect` blind. Just plug in, run the script, and unplug.

## Prerequisites

- An Android phone with:
  - **Developer Options** enabled
  - **USB Debugging** enabled
  - **Wi-Fi Hotspot** turned on
  - **USB Tethering** enabled (Settings → Network & Internet → Hotspot & Tethering)
  - **Mobile data** active (the script extracts the IP from `rmnet_data0`)
- A Linux machine
- A USB cable (used only during initial setup)

## Installation

### Clone the repository

```bash
git clone git@github.com:Musa-dabwe/ADB-Wireless-Connect-Script.git
cd ADB-Wireless-Connect-Script
chmod +x adb-wireless.sh
```

### Download directly

```bash
wget https://raw.githubusercontent.com/Musa-dabwe/ADB-Wireless-Connect-Script/main/adb-wireless.sh
chmod +x adb-wireless.sh
```

### Install dependencies

**ADB (required)**

```bash
# Debian / Ubuntu / Linux Mint
sudo apt install adb

# Fedora / RHEL / CentOS
sudo dnf install android-tools

# Arch / Manjaro
sudo pacman -S android-tools
```

**scrcpy (optional — for screen mirroring)**

```bash
# Debian / Ubuntu / Linux Mint
sudo apt install scrcpy

# Fedora / RHEL / CentOS
sudo dnf install scrcpy

# Arch / Manjaro
sudo pacman -S scrcpy
```

## Usage

```bash
./adb-wireless.sh
```

The script is fully interactive. Follow the on-screen prompts.

## How It Works

Below is a step-by-step breakdown of everything the script does.

### 1. Banner

Displays the script title and purpose.

### 2. ADB Check

Verifies that `adb` (Android Debug Bridge) is installed. If missing, it prints the install command for your distribution and exits.

### 3. USB Connection Prompt

Instructs you to connect your phone via USB with Developer Options, USB Debugging, Wi-Fi Hotspot, and USB Tethering enabled. Waits for you to press Enter.

### 4. ADB Server Restart

Runs `adb kill-server` and `adb start-server` to ensure a clean ADB state.

### 5. Device Detection

Runs `adb devices` and extracts the first device ID that shows a `device` status. If none is found, the script exits with an error.

### 6. IP Extraction

Runs `adb -s <device_id> shell ip addr show rmnet_data0` and parses the output with `grep -oP 'inet \K[\d.]+'` to extract the IP address. If `rmnet_data0` is not found, the script guides you to check available interfaces.

### 7. TCP/IP Mode

Runs `adb -s <device_id> tcpip 5555` to tell the phone to listen for ADB connections over TCP on port 5555. Waits 2 seconds for the change to take effect.

### 8. Wireless Connect

Runs `adb connect <ip>:5555`. If the connection attempt returns an error (failed/unable/error), it waits 3 seconds and retries once.

### 9. Verify Connection

Prints the output of `adb devices` so you can see both the USB and the new wireless connection.

### 10. USB Disconnect & Re-verify

Prompts you to disconnect the USB cable. After you press Enter, it runs `adb devices` again and checks that the device is still listed under `<ip>:5555`. Confirms success or alerts if the device dropped.

### 11. scrcpy Keyboard Shortcuts

Displays a reference table of useful scrcpy shortcuts (Home, Back, Switch apps, Fullscreen, etc.).

### 12. scrcpy Launch

Checks if `scrcpy` is installed. If found, it launches scrcpy in the background with `nohup` so your terminal stays usable. If not found, it prompts you to install it or skip.

## Troubleshooting

| Issue | Likely Cause | Solution |
|-------|-------------|----------|
| `No device found` | USB debugging not enabled | Enable Developer Options → USB Debugging on the phone |
| `Could not extract IP from rmnet_data0` | Mobile data off or interface named differently | Turn on mobile data; run `adb shell ip addr show` to find the correct interface |
| `connection failed` | Device not in TCP/IP mode | The script retries automatically; ensure USB cable is still connected during the `tcpip` step |
| `unauthorized` on wireless connection | Not yet trusted | Check the phone screen for the RSA key fingerprint prompt and accept it |
| `scrcpy not found` | scrcpy not installed | Install scrcpy (see Installation section) or press Ctrl+C to skip |

## scrcpy Keyboard Shortcuts

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

## Requirements

- **OS:** Linux (Debian/Ubuntu/Fedora/Arch)
- **Shell:** Bash 4+
- **adb:** Android Debug Bridge (`android-platform-tools`)
- **scrcpy:** Optional, for screen mirroring
- **Phone:** Android 5.0+ with Developer Options and USB Debugging

## License

[MIT](LICENSE.md)

## Contributing

Pull requests are welcome. For significant changes, open an issue first to discuss what you would like to change.
