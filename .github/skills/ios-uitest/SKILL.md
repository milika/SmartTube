---
name: ios-uitest
description: >
  Expert guidance on iOS UI Test authoring, execution, and debugging for the
  SmartTube iOS project. Use when: (1) writing or fixing XCUITest code,
  (2) running UI tests via MCP Xcode tools, (3) diagnosing flaky or failing
  UI tests, (4) reading build output and errors, (5) managing simulator state.
compatibility: >
  Requires MCP Xcode tools (mcp_xcode_*) for primary workflow. CLI fallbacks via
  run_in_terminal for simulator state and xcresult parsing.
  Project: SmartTube.xcworkspace (SmartTubeApp + SmartTubeIOS SwiftPM package).
allowed-tools: Read Grep Glob Shell Write BuildProject RunAllTests RunSomeTests GetTestList GetBuildLog XcodeListWindows XcodeRead XcodeUpdate XcodeWrite XcodeGrep XcodeGlob XcodeLS XcodeRefreshCodeIssuesInFile XcodeListNavigatorIssues
metadata:
  version: "1.2"
---

# iOS UI Test Skill

## Overview

This skill captures **live, battle-tested patterns** from E2E UI test work in this
monorepo. Treat it as the authoritative guide for any agent running, writing, or
debugging UI tests here. The patterns below were derived from real failures and
the fixes that resolved them — not from documentation.

**Primary tooling: MCP Xcode tools** — use these for all build, test, read, write,
and search operations. Fall back to `run_in_terminal` only for tasks MCP cannot
perform (simulator state, xcresult parsing, test plans not active in Xcode).

---

## Agent Behavior Contract (Always Follow These Rules)

1. **Resolve `tabIdentifier` first.** Every MCP Xcode tool requires it. Call `mcp_xcode_XcodeListWindows()` at the start of every session and reuse the result.
2. **Get exact test identifiers from `GetTestList`.** Do not guess `testIdentifier` format. Copy it verbatim from the tool output.
3. **New UI test files must be registered in `project.pbxproj`.** SmartTubeUITests is a classic Xcode target — SwiftPM auto-discovery does not apply (see Section 9).
4. **After editing `project.pbxproj`, always run `xcodebuild clean` before rebuilding.** Xcode may serve a stale cached binary otherwise.
5. **Never use `Process` or `Pipe` in UI test files.** They are macOS-only. Use UI-observable signals (alerts, labels) to detect errors instead.
6. **Use `element.frame` to check visibility before tapping.** Calling `.isHittable` or `.tap()` on a partially off-screen element throws "Activation point invalid".
7. **Plan for 3–6 execution cycles** before a new E2E test is stable. Each cycle typically surfaces a different class of failure (Section 8).

---

## Reference Files

Load these files as needed for the specific task at hand:

| Reference | When to load |
|---|---|
| [references/authoring-patterns.md](references/authoring-patterns.md) | Writing or fixing XCUITest code — login detection, polling loops, modals, accessibility IDs, TEMP intervals |
| [references/simulator.md](references/simulator.md) | Simulator setup — UDID, GPS location, keychain reset, app install/launch; also test account and env config |
| [references/read-results.md](references/read-results.md) | Parsing build logs (MCP) or xcresult pass/fail output (CLI) after a test run |
| [references/debugging.md](references/debugging.md) | Live test debugging — navigator issues, diagnostics refresh, log streaming, post-mortem inspection |

---

## 1. Repository Structure (UI Tests)

```
SmartTube.xcworkspace
SmartTubeApp/
  SmartTubeApp.xcodeproj/
    project.pbxproj             ← UI test Swift files MUST be registered here
  UITests/
    CategoryChipHTTP400UITests.swift
    PlayerNavigationUITests.swift
    PlaylistsNavigationUITests.swift
    ShortsNavigationUITests.swift
SmartTubeIOS/
  Package.swift                 ← SwiftPM package (SmartTubeIOS + SmartTubeIOSCore)
  Tests/SmartTubeIOSTests/      ← unit/integration tests
```

The `SmartTubeUITests` target is a **classic Xcode target** (not SwiftPM).
New UI test files must be manually registered in `project.pbxproj` (see Section 9).
The `SmartTubeIOS` unit tests are SwiftPM-managed and do not need `project.pbxproj` registration.

---

## 2. MCP Xcode: Primary Workflow

### Step 0 — Always resolve the tabIdentifier first
Every MCP Xcode tool requires a `tabIdentifier`. Get it once at the start of any
task and reuse it throughout the session:
```
mcp_xcode_XcodeListWindows()
→ returns: [{ tabIdentifier: "...", workspacePath: "...", ... }]
```
Use the `tabIdentifier` from the window showing the relevant workspace.

---

### Build
```
mcp_xcode_BuildProject(tabIdentifier: "<tab>")
```
Builds the currently active scheme. Use this to verify compilation after code
changes before running tests.

**Read build errors immediately after** — see [references/read-results.md](references/read-results.md).

---

### Discover available tests
Before running specific tests, always discover them to get exact identifiers:
```
mcp_xcode_GetTestList(tabIdentifier: "<tab>")
→ returns: up to 100 tests + fullTestListPath (grep-friendly file)
```
The full list is at `fullTestListPath`. Search it:
```bash
grep "TEST_TARGET=<TargetName>" <fullTestListPath>
# Each line has: TEST_TARGET, TEST_IDENTIFIER, TEST_FILE_PATH
```
Use the `TEST_IDENTIFIER` value as `testIdentifier` in `RunSomeTests`.

⚠️ `GetTestList` reflects the **active test plan** only. If the target you want
is not in the active plan, use the CLI fallback in Section 3.

---

### Run all tests (active test plan)
```
mcp_xcode_RunAllTests(tabIdentifier: "<tab>")
```

### Run specific tests
```
mcp_xcode_RunSomeTests(
  tabIdentifier: "<tab>",
  tests: [
    { targetName: "<TestTargetName>", testIdentifier: "<Suite>/test_method" },
    { targetName: "<TestTargetName>", testIdentifier: "<Suite>/test_other" }
  ]
)
```
`testIdentifier` format: `SuiteName/testMethodName` (no parens, no module prefix).
Always copy the exact value from `GetTestList` output.

---

### Read a file
```
mcp_xcode_XcodeRead(
  tabIdentifier: "<tab>",
  filePath: "<ProjectName>/Sources/MyFeature/MyFile.swift"
)
```
⚠️ `filePath` is the **Xcode project navigator path**, not a filesystem path.
Use `XcodeLS` or `XcodeGrep` to discover the correct project-relative path.

### Edit a file
```
mcp_xcode_XcodeUpdate(
  tabIdentifier: "<tab>",
  filePath: "<project-navigator-path>",
  oldString: "<exact text to replace>",
  newString: "<replacement text>"
)
```
Requires exact literal match of `oldString`. Use `XcodeRead` first to copy the
exact text including indentation.

### Create / overwrite a file
```
mcp_xcode_XcodeWrite(
  tabIdentifier: "<tab>",
  filePath: "<project-navigator-path>",
  content: "<full file content>"
)
```
Automatically adds new files to the Xcode project structure.

---

### Search within the project
```
// Find files by pattern (glob)
mcp_xcode_XcodeGlob(
  tabIdentifier: "<tab>",
  pattern: "**/*UITests*.swift"
)

// Search file content by regex
mcp_xcode_XcodeGrep(
  tabIdentifier: "<tab>",
  pattern: "accessibilityIdentifier",
  glob: "**/*.swift",
  outputMode: "content",
  showLineNumbers: true,
  linesContext: 2
)
```

### List directory / navigate structure
```
mcp_xcode_XcodeLS(
  tabIdentifier: "<tab>",
  path: "SmartTubeApp/UITests",
  recursive: false
)
```

---

## 3. When to Fall Back to CLI

Use `run_in_terminal` only when MCP cannot do the job:

| Situation | Why MCP can't | CLI fallback |
|---|---|---|
| Clean build after `project.pbxproj` edit | MCP build may use stale cache | `xcodebuild clean -project SmartTubeApp/SmartTubeApp.xcodeproj -scheme SmartTube` |
| Simulator state (boot, keychain) | No MCP tool for `simctl` | `xcrun simctl ...` — see [references/simulator.md](references/simulator.md) |
| Parse xcresult for per-test pass/fail | No MCP xcresult tool | `xcresulttool` + `python3` — see [references/read-results.md](references/read-results.md) |
| Stream live app logs during a test | No MCP log stream | `xcrun simctl spawn booted log stream` — see [references/debugging.md](references/debugging.md) |

### CLI: Clean build
```bash
cd /Users/milikadelic/SmartTube/SmartTubeApp
xcodebuild clean -project SmartTubeApp.xcodeproj -scheme SmartTube
# Then rebuild via mcp_xcode_BuildProject
```

---

## 4. Unit Tests vs. UI Tests — Decision Guide

| Need | Use |
|---|---|
| Verify InnerTube parsing logic | Unit test (SmartTubeIOSTests) |
| Verify a network error surfaces as a UI alert | UI test |
| Verify business logic in isolation | Unit test |
| Verify E2E navigation flows | UI test |
| Verify a chip/tab triggers the correct feed | UI test |

---

## 5. Running UI Tests Outside MCP

When running from the terminal directly:
```bash
cd /Users/milikadelic/SmartTube/SmartTubeApp
xcodebuild test \
  -project SmartTubeApp.xcodeproj \
  -scheme SmartTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices | grep Booted | grep -oE '[A-F0-9-]{36}' | head -1)" \
  CODE_SIGNING_ALLOWED=NO
```

Prefer `mcp_xcode_RunSomeTests` — it is faster and surfaces results directly.

---

## 6. What to Avoid (Anti-Patterns)

| Anti-pattern | Why | Fix |
|---|---|---|
| Using `run_in_terminal` to read/write Swift files | Fragile, bypasses Xcode | `mcp_xcode_XcodeRead` / `mcp_xcode_XcodeUpdate` |
| Using `Process` in a UI test file | `Process` is macOS-only; UI test targets compile for iOS | Use UI-observable signals instead (alerts, accessibility elements) |
| `element.tap()` on a partially off-screen element | XCTest internally calls `isHittable` and throws "Activation point invalid" | Scroll element fully into view first using container-relative coordinates |
| Calling `element.isHittable` on a partially off-screen element | Throws "Activation point invalid and no suggested hit points" for clipped elements | Use `element.frame` to determine visibility, then scroll before tapping |
| Complex descendant-traversal predicate inside `XCTNSPredicateExpectation` closure | `BEGINSWITH` queries in a polling closure trigger XCTest snapshot timeouts during view transitions | Use `element.waitForExistence(timeout:)` on a single known element, or a fixed `Thread.sleep` |
| Scrolling a horizontal chip bar using app-level screen coordinates | Gestures may land outside the bar and interact with other elements | Use container-relative coordinates: `chipBar.coordinate(withNormalizedOffset: CGVector(dx:, dy:))` |
| Asserting HTTP-layer errors via OS log in a UI test | `Process`/`Pipe` are macOS-only | Assert the UI signal that the error produces instead (e.g. an alert) |
| Calling any MCP tool without `tabIdentifier` | All tools require it — will error | Always call `XcodeListWindows` first |
| Copying a `testIdentifier` by guessing | Format must be exact | Get it from `GetTestList` output |
| Not running `xcodebuild clean` after `project.pbxproj` edits | Xcode may use cached binary where the new test doesn't exist | Run `xcodebuild clean -project SmartTubeApp.xcodeproj -scheme SmartTube` |

---

## 7. Quick Triage — Test Failure Symptom → Fix

Fast-path lookup for the most common failures.

| Symptom | Likely cause | Fix |
|---|---|---|
| MCP tool call errors with `tabIdentifier` missing | `tabIdentifier` not resolved | Call `mcp_xcode_XcodeListWindows()` at session start (Section 2) |
| Test not found / wrong identifier | Guessed `testIdentifier` format | Copy exact value from `mcp_xcode_GetTestList` (Section 2) |
| `RunSomeTests` returns `state: "not run"` with no error | Xcode using cached binary after `project.pbxproj` edit | `xcodebuild clean`, then rebuild (Section 3) |
| Build succeeds but new test class missing from `GetTestList` | Stale cached binary | `xcodebuild clean -project SmartTubeApp.xcodeproj -scheme SmartTube` |
| `Process` type not found in UI test | `Process` is macOS-only | Replace with UI-observable signal (alert/label) — see Section 11 |
| "Activation point invalid" on chip/button tap | Element partially off-screen; `element.tap()` throws | Use `element.frame` loop to scroll into view (authoring-patterns.md §scroll) |
| XCTest snapshot timeout in predicate closure | Descendant query (`BEGINSWITH`) inside `XCTNSPredicateExpectation` during view transition | Use `waitForExistence` on a single element or `Thread.sleep` |
| Error alert appears after tapping a category chip | HTTP error from InnerTube for that feed | Check the InnerTube logs for the browse ID / client context |
| `osascript` fails to type into simulator | `osascript` operates on macOS UI, not simulator | Use `typeText(_:)` in XCUITest |
| `log stream` exits with code 143 | Normal SIGTERM on app termination | Not an error — ignore exit code 143 |

---

## 8. Iterative UI Test Development Expectation

A new E2E UI test rarely passes on the first run. Plan for **3–5 execution cycles**
before a test is stable. Each cycle surfaces a different class of failure:

| Cycle | Typical failure | Fix |
|---|---|---|
| 1 | Build error (e.g. macOS-only API, missing `project.pbxproj` entry) | Fix compile error, register file, clean build |
| 2 | `RunSomeTests` returns `not run` | `xcodebuild clean`, verify `GetTestList` shows the test |
| 3 | Element interaction throws (off-screen, snapshot timeout) | Use `element.frame` scroll loop; use `Thread.sleep` instead of predicate wait |
| 4 | False pass or false fail due to view transition timing | Add/increase `waitForFeedToSettle` interval |
| 5 | Intermittent failure on slow network | Increase network wait timeout |

**Practical workflow:**
1. Write minimal test, run once, read the failure
2. Fix the specific failure, not the whole test
3. Repeat until 2 consecutive passing runs
4. Only then clean up and commit

---

## 9. Adding New UI Test Files

The `SmartTubeUITests` target is a **classic Xcode target**. New files in `SmartTubeApp/UITests/`
must be manually registered in `project.pbxproj` with four entries:

```
// 1. PBXBuildFile — links the file into the build phase
<BUILD_UUID> /* MyTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILE_UUID> /* MyTests.swift */; };

// 2. PBXFileReference — declares the file on disk
<FILE_UUID> /* MyTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MyTests.swift; sourceTree = "<group>"; };

// 3. UITests group children — makes it appear in the navigator
<FILE_UUID> /* MyTests.swift */,

// 4. PBXSourcesBuildPhase files list — compiles it
<BUILD_UUID> /* MyTests.swift in Sources */,
```

Use unique hex IDs (e.g. `F4A5B6C7D8E9F0A1B2C3D4E5`). Copy a neighbour entry and
change the UUIDs and filename — the format must match exactly.

After editing `project.pbxproj`:
1. Run `xcodebuild clean -project SmartTubeApp/SmartTubeApp.xcodeproj -scheme SmartTube`
2. `mcp_xcode_BuildProject(tabIdentifier:)` — verify compilation
3. `mcp_xcode_GetTestList(tabIdentifier:)` — verify the new test appears

⚠️ If a build succeeds but the test still shows as `not run`, run `xcodebuild clean` and rebuild.

---

## 10. Quick Checklist Before Running UI Tests

- [ ] Get `tabIdentifier`: `mcp_xcode_XcodeListWindows()`
- [ ] Build succeeds: `mcp_xcode_BuildProject(tabIdentifier:)`
- [ ] No build errors: `mcp_xcode_GetBuildLog(tabIdentifier:, severity: "error")`
- [ ] Test identifiers verified: `mcp_xcode_GetTestList(tabIdentifier:)`
- [ ] Simulator booted: `xcrun simctl list devices | grep Booted`
- [ ] Accessibility IDs set on all queried elements

---

## 11. Patterns from SmartTube Category-Chip HTTP Error Test

Learned from writing and stabilising `CategoryChipHTTP400UITests`. Apply these
patterns to any test involving a horizontal scroll container, network requests,
or error-state detection without direct log access.

### 11.1 Detecting HTTP errors without OS log access

UI test targets compile for iOS — `Process`, `Pipe`, and `xcrun simctl log stream`
are **not available**. To assert that an HTTP error did NOT occur:

1. Find the UI signal the app already produces for errors — in SmartTube,
   `BrowseViewModel` sets `vm.error` which `BrowseView` renders as an `alert("Error", ...)`.
2. Assert that signal is **absent** after each action.

```swift
let errorAlert = app.alerts["Error"]
XCTAssertFalse(
    errorAlert.exists,
    "An Error alert appeared — HTTP error returned for the '\(chipName)' chip"
)
// Dismiss if present so test can continue
if errorAlert.exists { errorAlert.buttons.firstMatch.tap() }
```

This pattern works for any network-backed view that surfaces errors via alerts,
empty-state text, or accessibility-identified labels.

### 11.2 Scrolling a horizontal chip/tab bar reliably

Use **chip-bar-relative coordinates** for all scroll gestures. App-level screen
coordinates are fragile because the bar's vertical position varies by device.

```swift
// Coordinates pinned to chipBar, not the full app
let near = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
let far  = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))

// Scroll right → reveals leading chips
near.press(forDuration: 0.05, thenDragTo: far)

// Scroll left → reveals trailing chips
far.press(forDuration: 0.05, thenDragTo: near)
```

### 11.3 Tapping a chip that may be partially off-screen

Do NOT use `element.isHittable` or `element.tap()` before the element is fully
on-screen — both throw "Activation point invalid" for clipped elements.

Instead, use `element.frame` (safe for off-screen elements — does not throw) to
decide the scroll direction, then tap only when in-bounds:

```swift
let screenWidth = app.windows.firstMatch.frame.width
for _ in 0..<8 {
    let frame = chip.frame
    guard frame.origin.x < 4 || frame.maxX > screenWidth - 4 else { break }
    if frame.origin.x < 4 {
        near.press(forDuration: 0.05, thenDragTo: far)  // scroll right
    } else {
        far.press(forDuration: 0.05, thenDragTo: near)  // scroll left
    }
}
chip.tap()  // now safely on screen
```

### 11.4 Waiting for a network-triggered view to settle

Avoid complex `XCTNSPredicateExpectation` closures that traverse descendants
(e.g. `BEGINSWITH 'video.card.'`) — these trigger XCTest snapshot timeouts
during active view-hierarchy transitions.

For network tests where a fixed upper-bound wait is acceptable, a `Thread.sleep`
is the most reliable option:

```swift
private func waitForFeedToSettle() {
    Thread.sleep(forTimeInterval: 5)
}
```

For tests where you want to proceed as soon as content is ready, use
`waitForExistence` on a **single, already-materialised** element (not a query
that must traverse the whole tree):

```swift
let spinner = app.activityIndicators.firstMatch
if spinner.waitForExistence(timeout: 3) {
    let gone = NSPredicate(format: "exists == false")
    _ = XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: gone, object: spinner)],
        timeout: 15
    )
}
```

### 11.5 Registering a file in a classic Xcode target (project.pbxproj)

See Section 9 — Classic Xcode targets for the four-entry registration template.
Key lesson: after editing `project.pbxproj`, always run `xcodebuild clean` before
rebuilding. Xcode may otherwise serve a stale cached binary where the new test
method does not exist, causing `RunSomeTests` to return `state: "not run"` with
no error message.

```bash
xcodebuild clean -project SmartTubeApp/SmartTubeApp.xcodeproj -scheme SmartTube
```

Then rebuild via `mcp_xcode_BuildProject` before running tests.
