# Debugging Live Test Runs

## Check build issues mid-session (MCP)
```
mcp_xcode_XcodeListNavigatorIssues(tabIdentifier: "<tab>", severity: "error")
```

## Refresh diagnostics for a specific file (MCP)
After editing a file, force Xcode to re-evaluate diagnostics:
```
mcp_xcode_XcodeRefreshCodeIssuesInFile(
  tabIdentifier: "<tab>",
  filePath: "<project-navigator-path>"
)
```

---

## Stream simulator logs during a live test (CLI — MCP cannot do this)
```bash
# Shorthand: use 'booted' instead of a UDID when exactly one simulator is booted
xcrun simctl spawn booted log stream \
  --level debug \
  --predicate 'process == "<AppProcessName>" AND (
    category == "<RelevantLogCategory>" OR
    eventMessage CONTAINS[c] "<keyword>"
  )' 2>&1 | tee /tmp/test_monitor.log

# Or with explicit UDID (if multiple simulators are booted):
SIM_UDID=$(xcrun simctl list devices | grep Booted | grep -oE '[A-F0-9-]{36}' | head -1)
xcrun simctl spawn "$SIM_UDID" log stream --level debug \
  --predicate 'process == "<AppProcessName>"' 2>&1
```
- `<AppProcessName>` — the process name visible in Xcode's Debug Navigator when
  the app runs on the simulator (usually matches the app target name).
- `<RelevantLogCategory>` — the `os_log` category string used by the subsystem
  under test. Find it with `XcodeGrep` searching for `OSLog` or `Logger` usage.

## Post-mortem log inspection (CLI)
```bash
log show --last 10m \
  --predicate 'process == "<AppProcessName>"' \
  --info 2>/dev/null | grep -i 'error\|fail\|<feature-keyword>'
```

---

## ⚠️ Known CLI Gotchas

- **`log stream` exits with code 143 (SIGTERM)** when the app terminates. This is normal — do not treat it as a tool failure.
- **`osascript` cannot type into the iOS Simulator.** `osascript` operates on macOS UI elements, not the simulator's internal view hierarchy. Never attempt `keystroke` or `tell application "Simulator"` for text input. Use XCTest's `typeText(_:)` from within a UI test instead.
