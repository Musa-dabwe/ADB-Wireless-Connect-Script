# ADB Wireless Connect Script Build Pamphlet

## Overview
- Purpose: Automate wireless Android ADB connections and launch scrcpy screen mirroring.
- Current Version: Unreleased
- Status: Stable Scripts

## Development Timeline

### 2026-09-26 — scrcpy USB support and clearer device diagnostics
`scrcpy.sh` filtered the device list to wireless `host:port` serials, so a USB-connected phone was reported as absent. Detection is now transport-aware (USB, wireless, emulator), and `unauthorized` / `offline` devices plus a missing `adb` binary each report their own fix instead of a generic "connect a device" message.
Session: docs/sessions/session-2026-09-26-1042-scrcpy-usb-support.md

### 2026-09-25 — Reliable scrcpy startup reporting
Diagnosed the libbluray ABI mismatch and fixed the launcher to surface startup failures, retain logs, and preserve background operation.
Session: docs/sessions/session-2026-09-25-0821-fix-scrcpy-launcher.md

## Architecture Overview
The project consists of three Bash entry points: `start.sh` establishes wireless ADB connectivity, `stop.sh` disconnects devices or stops the ADB server, and `scrcpy.sh` selects an authorized connected device — USB, wireless, or emulator — and launches a background scrcpy process with retained diagnostics.

## Bugs Discovered & Fixed
### Critical
- scrcpy could not start because the installed scrcpy binary required `libbluray.so.4` while the system provided `.so.3`. Resolved by updating the ABI-coupled `libbluray` and `mpv` packages.
- `scrcpy.sh` rejected USB-connected devices as "no wireless ADB devices found". The device list was filtered by a wireless-only `host:port` regex; detection is now transport-aware.

### Medium
- `scrcpy.sh` discarded scrcpy output and reported success even when the process exited immediately. The launcher now verifies startup, surfaces errors, propagates failure status, and records output in a unique per-launch log under the user state directory.
- Devices in `unauthorized` or `offline` state were silently dropped and reported as absent. They are now named with state-specific remediation.
- A missing `adb` binary was misreported as "no connected devices"; an explicit presence check now reports it as such.

### Low
- Out-of-range input in the multi-device picker produced an empty serial instead of falling back to the first device.

## Testing Methodology
- Unit testing: Bash subprocess regression tests for immediate and delayed startup failure, background success, concurrent log isolation, and device detection across USB / wireless / emulator / unauthorized / offline / empty / missing-adb cases.
- Integration testing: Direct and scripted scrcpy launches against both USB and wireless ADB devices.
- Manual testing: OPPO PCLM50 on Android 12, Wayland session, Mesa OpenGL renderer.

## AI Models & Their Contributions
### Architecture & Complex Logic
- **Space Bunny Free**: Diagnosed the package ABI mismatch and designed the startup-verification behavior.

### Code Generation & Refactoring
- **Space Bunny Free**: Implemented the launcher fix and regression test suite.
- **Space Bunny Free**: Added transport-aware device detection and per-state diagnostics to the launcher.

### Specific Implementations
- None.

## Build Outputs
Location: `~/storage/shared/Docs/Build/`

## Development Resources
- Version Control: Git
- Runtime: Bash, Android Platform Tools, scrcpy
- Testing: Bash regression harness, `bash -n`, `git diff --check`

## Future Roadmap
- [ ] Make the scrcpy startup grace period configurable.
- [ ] Test normal audio forwarding separately from `--no-audio` startup.
