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

⚠️ **Simulator logs are NOT in the macOS unified log store.** Running `log show` directly
on the host returns nothing for simulator processes. You must proxy through `simctl spawn`.

```bash
# 1. Get the booted simulator UDID
SIM_UDID=$(xcrun simctl list devices | grep Booted | grep -oE '[A-F0-9-]{36}' | head -1)
echo "Booted simulator: $SIM_UDID"

# 2. Show all SmartTube logs in a time window (set --start / --end to bracket the test run)
xcrun simctl spawn "$SIM_UDID" log show \
  --start "YYYY-MM-DD HH:MM:SS" \
  --end   "YYYY-MM-DD HH:MM:SS" \
  --predicate 'subsystem == "com.void.smarttube.app"' \
  --info 2>/dev/null

# 3. Narrow to InnerTube HTTP calls only
xcrun simctl spawn "$SIM_UDID" log show \
  --start "YYYY-MM-DD HH:MM:SS" \
  --end   "YYYY-MM-DD HH:MM:SS" \
  --predicate 'subsystem == "com.void.smarttube.app" AND category == "InnerTube"' \
  --info 2>/dev/null | grep -E '(HTTP|POST|✅|❌)'
```

**Reading the output** — each line has the pattern:
```
<timestamp> <threadID> Default|Error 0x<activity> <pid> 0    SmartTube: … [com.void.smarttube.app:<Category>] <message>
```
- `Default` = normal log line; `Error` = logged at `.error` level (e.g. HTTP 400)
- `✅ /browse [TV] HTTP 200` = success; `❌ HTTP 400 for /browse [TV-category]` = failed request (may be caught by a fallback — check subsequent lines)

---

## ⚠️ Known CLI Gotchas

- **`log stream` exits with code 143 (SIGTERM)** when the app terminates. This is normal — do not treat it as a tool failure.
- **`osascript` cannot type into the iOS Simulator.** Use XCTest's `typeText(_:)` from within a UI test instead.
