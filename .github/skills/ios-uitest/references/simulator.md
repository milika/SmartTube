# Simulator Management (CLI-only)

No MCP Xcode tool controls the simulator directly. All simulator operations
require `run_in_terminal`.

```bash
# Resolve booted simulator UDID dynamically (never hardcode)
SIM_UDID=$(xcrun simctl list devices | grep Booted | grep -oE '[A-F0-9-]{36}' | head -1)

# Reset keychain — do this before UI tests on a freshly booted simulator
# if the app uses the keychain (e.g. for stored OAuth tokens).
xcrun simctl keychain "$SIM_UDID" reset

# Install and launch (when running outside xcodebuild test)
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData \
  -name 'SmartTube.app' -path '*/Debug-iphonesimulator/*' 2>/dev/null | head -1)
xcrun simctl install "$SIM_UDID" "$APP_PATH"
xcrun simctl launch "$SIM_UDID" com.void.smarttube.app
```
