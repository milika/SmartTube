# Simulator Management (CLI-only)

No MCP Xcode tool controls the simulator directly. All simulator operations
require `run_in_terminal`.

```bash
# Resolve booted simulator UDID dynamically (never hardcode)
SIM_UDID=$(xcrun simctl list devices | grep Booted | grep -oE '[A-F0-9-]{36}' | head -1)

# Set GPS location (required for location/jurisdiction-sensitive tests)
# Coordinates are in the project's GPX files or test inline comments
xcrun simctl location "$SIM_UDID" set <lat>,<lon>
xcrun simctl location "$SIM_UDID" clear   # reset to default

# Reset keychain — do this before UI tests on a freshly booted simulator.
# Without it the app may crash silently at keychain access with no test error output.
xcrun simctl keychain "$SIM_UDID" reset

# Install and launch (when running outside xcodebuild test)
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData \
  -name '<YourApp>.app' -path '*/Debug-iphonesimulator/*' 2>/dev/null | head -1)
xcrun simctl install "$SIM_UDID" "$APP_PATH"
xcrun simctl launch "$SIM_UDID" <com.your.bundle.id>
```

---

## Test Account & Environment Config

- Test credentials are stored in the project's secure credential store (e.g.,
  1Password, CI secrets, or an internal wiki). **Never hardcode them in test source
  files or skill files.**
- Retrieve credentials at test setup time via environment variables or a
  dedicated test credential helper, not inline strings.
- The target environment (production, QA, staging) is controlled via a launch
  argument (e.g., `DEBUG_RELEASE`) set in the test plan or via `LaunchHelper.launchApp(with:)`.
- The location scenario GPX file must match the jurisdiction required by the test.
  Set it in the `.xctestplan` file, not in the test source.
