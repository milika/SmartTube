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
  filePath: "SmartTubeApp/UITests/MyTests.swift"
)
```

---

## Stream simulator logs during a live test (CLI — MCP cannot do this)

SmartTube logs use `os.Logger` with subsystem `com.void.smarttube.app` and
categories: `InnerTube`, `Home`, `Browse`, `Player`, `Auth`, `Playlist`, `Download`.

```bash
# Filter to InnerTube API calls only (HTTP errors, request/response)
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "com.void.smarttube.app" AND category == "InnerTube"' \
  --style compact

# Broader — all SmartTube log output
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "com.void.smarttube.app"' \
  --style compact
```

⚠️ `Process`/`Pipe` are macOS-only and cannot be used inside iOS UI test files.
    Run `log stream` in a separate terminal while the test executes in Xcode.

## Post-mortem log inspection (CLI)
```bash
log show --last 10m \
  --predicate 'subsystem == "com.void.smarttube.app"' \
  --info 2>/dev/null | grep -i 'error\|fail\|HTTP'
```

---

## ⚠️ Known CLI Gotchas

- **`log stream` exits with code 143 (SIGTERM)** when the app terminates. This is normal — do not treat it as a tool failure.
- **`osascript` cannot type into the iOS Simulator.** Use XCTest's `typeText(_:)` from within a UI test instead.
