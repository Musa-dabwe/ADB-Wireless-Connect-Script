# Research: scrcpy Launch Failure

## Search Terms Used
- `launch_scrcpy`
- `nohup scrcpy`
- `scrcpy -s`
- `scrcpy --version`
- `libbluray.so.4`

## Existing Code Found
- `scrcpy.sh`: Detects an executable named `scrcpy`, finds authorized wireless ADB devices, collects optional arguments, and launches scrcpy in the background.
- `scrcpy.sh:180`: Redirects both output streams to `/dev/null`, starts scrcpy asynchronously, and immediately reports success based only on receiving a PID.
- `scrcpy.sh:70-83`: Checks only whether `scrcpy` exists in `PATH`; it does not verify that the binary can load.
- `start.sh`: Uses direct output capture and explicit error handling for ADB operations, providing a pattern for surfacing subprocess failures.

## Similar Patterns
- `start.sh:_try_connect`: Captures command output with `2>&1`, checks it, and reports the actual failure.
- `start.sh:step_connect`: Returns a non-zero result when an operation fails so `set -e` can stop the script.
- Official scrcpy documentation confirms that `-s IP:PORT` is the correct option for selecting a TCP/IP device.

## New Implementation Required
- Detect an executable that exists but cannot start, including a missing shared library.
- Preserve background launch behavior, but do not report success until the scrcpy process survives an initial startup grace period.
- If scrcpy exits during that period, return its non-zero status and show its captured error output.
- Update stale installation guidance to use `pkexec`, never `sudo`.

## Implementation Plan
1. Add a regression test that runs the real launcher with controlled `adb` and failing `scrcpy` commands.
2. Confirm the test fails because the current launcher returns success and hides the subprocess error.
3. Add minimal startup verification and visible failure reporting to `launch_scrcpy`.
4. Run the regression test, shell syntax validation, and a real device launch.
