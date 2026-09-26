# ADB Wireless Connect Script

Automate connecting your Android phone to ADB over a wireless connection, with a separate script for `scrcpy` screen mirroring.

## 🌟 Features

- **Automated USB Setup**: Automatically detects USB-tethered phone, switches device to TCP/IP mode (`adb tcpip 5555` or custom port), extracts IP address, and connects wirelessly.
- **Android 11+ Wire-Free Pairing**: Pair over Wi-Fi using Android 11+ `adb pair` when no USB cable is available.
- **Smart Dynamic IP Detection**: Prefers Wi-Fi/hotspot interfaces (`wlan0`, `wlan1`, `ap0`, …), skips cellular/carrier-NAT IPs that are unreachable from your PC, and pings candidates to confirm reachability. If ICMP is blocked or ping fails, falls back to the first suitable Wi-Fi address.
- **Multi-Device Selector**: Displays an interactive menu if multiple USB devices are attached. Garbage or out-of-range input falls back to the first device instead of the wrong one.
- **scrcpy Launcher (`scrcpy.sh`)**: Standalone script with interactive resolution and FPS selection menus. Works with USB and wireless devices. Tracks the session through a PID file, bounds the log directory, and can run in the foreground with `--wait` so a mid-session crash is visible.
- **Dedicated Cleanup (`stop.sh`)**: Interactive or non-interactive wireless session disconnect and ADB server restart tool. Every wireless target is labelled with its real adb state, and a partial disconnect is never reported as success.
- **CLI Options**: Supports non-interactive flags like `--port`, `--timeout`, `--wait`, `--force`, `--all`, and `--kill`.
- **Input validation**: `--port` is checked at both of its input paths before adb ever sees it, and no failure path ends in a silent non-zero exit.

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
chmod +x start.sh stop.sh scrcpy.sh
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
`--force` escalates from `SIGTERM` to `SIGKILL` after about a second.

The log directory is the same `adb-wireless-connect` directory and holds one
`scrcpy.*.log` per launch. The newest 10 are kept, plus the current launch's log
whether or not it is among them; pruning runs on the failure path too, since a
device that will not start is exactly when a user retries.

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

## 🧪 Tests

Both suites are pure Bash and use mock `adb` / `scrcpy` / `ping` / `sleep`
binaries on `PATH`, driven by `MOCK_*` environment variables. No case contacts a
real device, and no case leaves a process running.

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
| `Alt + F` | Toggle fullscreen |
| `Alt + O` | Turn phone screen off |
| `Alt + P` | Power button |
| `Alt + Up` | Volume up |
| `Alt + Down` | Volume down |

---

## 📄 License

[MIT](LICENSE.md)
