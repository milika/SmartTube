---
name: ios-uitest
description: >
  Expert guidance on iOS UI Test authoring, execution, and debugging for this
  SwiftPM-based multi-brand workspace. Use when: (1) writing or fixing XCUITest
  code, (2) running UI tests via MCP Xcode tools, (3) diagnosing flaky or failing
  UI tests, (4) reading build output and errors, (5) managing simulator state for
  E2E scenarios, (6) hooking UI tests into CI (fastlane/xctestplan).
compatibility: >
  Requires MCP Xcode tools (mcp_xcode_*) for primary workflow. CLI fallbacks via
  run_in_terminal for simulator state, xcresult parsing, and non-active test plans.
  Designed for this SwiftPM monorepo (BetssonAll.xcworkspace / Modules/Package.swift).
allowed-tools: Read Grep Glob Shell Write BuildProject RunAllTests RunSomeTests GetTestList GetBuildLog XcodeListWindows XcodeRead XcodeUpdate XcodeWrite XcodeGrep XcodeGlob XcodeLS XcodeRefreshCodeIssuesInFile XcodeListNavigatorIssues
metadata:
  author: betsson
  version: "1.1"
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
2. **Run tests from `Modules/`**, never from the workspace root. The workspace root bleeds unrelated package errors and produces `** TEST FAILED **` even when the target passes.
3. **Never use `swift test`.** Use `xcodebuild` or MCP tools — `swift test` fails with macOS platform errors for this package.
4. **Get exact test identifiers from `GetTestList`.** Do not guess `testIdentifier` format. Copy it verbatim from the tool output.
5. **Reset the simulator keychain before UI tests on a fresh boot.** Omitting it causes a silent crash at startup with no test error output.
6. **Do not infer auth state from `.exists` or `.isHittable` on always-present buttons.** Both return `true` regardless of login state. Use the tap-and-observe strategy (references/authoring-patterns.md §6.2).
7. **Use deadline polling loops for timer-driven features**, not a single `waitForExistence(timeout:)`. Cover the full trigger + retrigger + jitter window.
8. **Plan for 3–6 execution cycles** before a new E2E test is stable. Each cycle typically surfaces a different class of failure (Section 8).

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
Modules/
  TESTING/
    BetssonArgentinaUITests/
      RealityCheckUITests.swift
      BetssonArgentinaUITests.xctestplan    ← active test plan (sets location scenario)
  PAM/
    ResponsibleGaming/
      Tests/
        ResponsibleGamingTests/             ← Unit tests run via UnitTests.xctestplan
          .../TimeIntervalDrivenExecutorTests.swift
BetssonAll.xcworkspace                      ← workspace for full-app schemes
Modules/Package.swift                       ← SwiftPM package with all test targets
Modules/UnitTests.xctestplan               ← test plan for unit tests
Modules/IntegrationTests.xctestplan
```

UI test targets live inside the `Modules` SwiftPM package.
Unit test targets also live inside `Modules`.
The full-app `BetssonAll.xcworkspace` is **not used** to run these tests.

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
  path: "Modules/TESTING",
  recursive: false
)
```

---

## 3. When to Fall Back to CLI

Use `run_in_terminal` only when MCP cannot do the job:

| Situation | Why MCP can't | CLI fallback |
|---|---|---|
| Run tests from a **non-active** test plan | `RunSomeTests`/`RunAllTests` bind to active plan | `cd Modules && xcodebuild test -testPlan <Name>` |
| Simulator state (boot, GPS, keychain) | No MCP tool for `simctl` | `xcrun simctl ...` — see [references/simulator.md](references/simulator.md) |
| Parse xcresult for per-test pass/fail | No MCP xcresult tool | `xcresulttool` + `python3` — see [references/read-results.md](references/read-results.md) |
| Stream live app logs during a test | No MCP log stream | `xcrun simctl spawn ... log stream` — see [references/debugging.md](references/debugging.md) |

### CLI: Run tests from a specific test plan
```bash
cd Modules && xcodebuild test \\
  -scheme Modules \\
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices | grep Booted | grep -oE '[A-F0-9-]{36}' | head -1)" \\
  -testPlan <TestPlanName> \\
  -only-testing:<TargetName>/<SuiteName>/test_foo \\
  -skipPackagePluginValidation \\
  CODE_SIGNING_ALLOWED=NO
```

⚠️ Always `cd Modules/` before running xcodebuild.
Running from the workspace root leaks build errors from unrelated packages and
produces `** TEST FAILED **` even when the target tests are fine.
⚠️ Never use `swift test` — fails with macOS platform errors for this package.

---

## 4. Unit Tests vs. UI Tests — Decision Guide

| Need | Use |
|---|---|
| Verify timing logic with parametrized intervals (e.g., 1min–1hour sweep) | Unit test + mock timer |
| Verify that popup actually appears on screen | UI test |
| Verify business logic in isolation | Unit test |
| Verify E2E user flows (login → RC popup) | UI test |
| Verify jurisdiction switching logic | Unit test |

For timer-driven features, shorten the production intervals to test-safe values
(e.g., `retriggerInterval = 30`, `investigationInterval = 10`) so the test
completes in under 2 minutes. Mark these overrides `// ⚠️ TEMP` and remove them
after the test phase. See [references/authoring-patterns.md](references/authoring-patterns.md) Section 9 for the TEMP pattern.

---

## 5. CI / Fastlane Integration

CI uses `xcodebuild` directly (MCP Xcode is not available in CI). The flags
applied locally also apply in CI:
- `-skipPackagePluginValidation` — required for non-interactive builds
- `CODE_SIGNING_ALLOWED=NO` — required for simulator destinations
- Run from `Modules/` directory for unit/UI tests targeting the SwiftPM package

Test plans are referenced in `FastfileBuildAndTest`. Changing which plan runs
requires editing that file, not a scheme change.

---

## 6. What to Avoid (Anti-Patterns)

| Anti-pattern | Why | Fix |
|---|---|---|
| Using `run_in_terminal` to read/write Swift files | Fragile, bypasses Xcode | `mcp_xcode_XcodeRead` / `mcp_xcode_XcodeUpdate` |
| Calling any MCP tool without `tabIdentifier` | All tools require it — will error | Always call `XcodeListWindows` first |
| Copying a `testIdentifier` by guessing | Format must be exact | Get it from `GetTestList` output |
| `RunSomeTests` for a test not in the active plan | MCP is bound to active plan | `xcodebuild test -only-testing:` CLI fallback |
| `xcodebuild` from workspace root for Modules tests | Unrelated package errors bleed in → `** TEST FAILED **` | Run from `Modules/` |
| `swift test` for Modules package | macOS platform errors | Use `xcodebuild` |
| `element.exists` on always-present header buttons to infer auth state | True in both logged-in and logged-out states | Tap-and-observe strategy |
| Single `waitForExistence(timeout: N)` for timer-driven features | No recovery if a blocking modal appears mid-wait | Deadline polling loop |
| Dismissing all alerts as "blockers" | May dismiss the very alert being tested | Check if alert IS the expected element first |
| Skipping keychain reset before UI tests on a fresh simulator | Silent crash at app startup, no test error shown | `xcrun simctl keychain "$SIM_UDID" reset` |
| Reading xcresult from the workspace DerivedData folder | Empty `ActionTestPlanRunSummaries` | Use the `Modules-<hash>` DerivedData folder |
| `xcresulttool` without `--legacy` | Different schema, fields missing | Always include `--legacy` |

---

## 7. Quick Triage — Test Failure Symptom → Fix

Fast-path lookup for the most common failures. Full fix details are in the referenced files.

| Symptom | Likely cause | Fix |
|---|---|---|
| App crashes silently at startup, no test error shown | Stale keychain on fresh simulator | `xcrun simctl keychain "$SIM_UDID" reset` (simulator.md) |
| `** TEST FAILED **` with no individual test errors | Running `xcodebuild` from workspace root | `cd Modules/` first (Section 3) |
| MCP tool call errors with `tabIdentifier` missing | `tabIdentifier` not resolved | Call `mcp_xcode_XcodeListWindows()` at session start (Section 2) |
| Test not found / wrong identifier | Guessed `testIdentifier` format | Copy exact value from `mcp_xcode_GetTestList` (Section 2) |
| `RunSomeTests` silently skips the test | Test not in active test plan | Use `xcodebuild test -testPlan` CLI fallback (Section 3) |
| Login detection always takes wrong branch | Using `.exists`/`.isHittable` on a header button | Tap-and-observe strategy (authoring-patterns.md §6.2) |
| Feature element never found | Wrong element type (`buttons` vs `otherElements`) | Custom VCs → `app.otherElements`; verify with `XcodeGrep` (authoring-patterns.md §6.3) |
| Timer-driven popup never appears in test | `waitForExistence` too short, no retry | Deadline polling loop with blocker dismissal (authoring-patterns.md §6.3) |
| Test accidentally dismisses the popup it's asserting | Treating target alert as a "blocker" | Check if alert IS the expected element first (authoring-patterns.md §6.4) |
| Post-login assertion fails intermittently | Welcome/onboarding modal blocks the view | Dismiss post-action modal before asserting (authoring-patterns.md §6.6) |
| `xcresult` summary is empty or fields missing | Reading wrong DerivedData folder or missing `--legacy` | Use `Modules-<hash>` folder; always pass `--legacy` (read-results.md) |
| `osascript` fails to type into simulator | `osascript` cannot reach simulator UI | Use `typeText(_:)` in XCUITest (debugging.md) |
| `log stream` exits with code 143 | Normal SIGTERM on app termination | Not an error — ignore exit code 143 (debugging.md) |
| Build errors from unrelated packages bleed in | Running `xcodebuild` from workspace root | `cd Modules/` (Section 3) |
| `swift test` fails with macOS platform errors | Wrong command for this package | Use `xcodebuild` instead (Section 3) |

---

## 8. Iterative UI Test Development Expectation

A new E2E UI test rarely passes on the first run. Plan for **3–6 execution cycles**
before a test is stable. Each cycle surfaces a different class of failure:

| Cycle | Typical failure | Fix |
|---|---|---|
| 1 | App crash at startup | Keychain reset, simulator state |
| 2 | Post-launch modal blocks the test flow | Dismiss startup dialogs |
| 3 | Login detection produces wrong branch | Tap-and-observe strategy |
| 4 | Feature element never found (wrong type/ID) | `app.otherElements` vs `app.buttons`; add accessibility ID |
| 5 | Test accidentally dismisses the feature being asserted | Check if alert is target before dismissing |
| 6 | Intermittent: blocking modal appears mid-poll | Add blocker dismissal inside poll loop |

**Practical workflow:**
1. Write minimal test, run once, read the failure
2. Fix the specific failure, not the whole test
3. Repeat until 2 consecutive passing runs
4. Only then clean up and commit

---

## 9. Adding New UI Test Files

All UI test targets in this repo are declared in `Package.swift` files (SwiftPM).
`project.pbxproj` is **not** involved for these targets — do not attempt to register
files there.

**SwiftPM default source discovery applies:** When a `testTarget` in `Package.swift`
does not specify an explicit `sources` list, SwiftPM automatically includes all `.swift`
files found under the target's directory. No manual registration is required.

**To add a new `*UITests.swift` file:**
1. Place the file inside the existing target directory (e.g. `Sources/<TargetName>/`).
2. Verify the containing `Package.swift` has a `testTarget` (or `.testTarget`) entry
   for that directory — no `sources` parameter needed unless the target already uses one.
3. Build to confirm SwiftPM picks it up: `mcp_xcode_BuildProject(tabIdentifier:)`

If the target uses an explicit `sources` list, append the new filename to that list in
`Package.swift`.

---

## 10. Quick Checklist Before Running UI Tests

- [ ] Get `tabIdentifier`: `mcp_xcode_XcodeListWindows()`
- [ ] Build succeeds: `mcp_xcode_BuildProject(tabIdentifier:)`
- [ ] No build errors: `mcp_xcode_GetBuildLog(tabIdentifier:, severity: "error")`
- [ ] Test identifiers verified: `mcp_xcode_GetTestList(tabIdentifier:)`
- [ ] Simulator booted: `xcrun simctl list devices | grep Booted`
- [ ] Keychain reset: `xcrun simctl keychain "$SIM_UDID" reset`
- [ ] GPS location set (if jurisdiction-sensitive)
- [ ] Test intervals short (≤60s investigation, ≤30s retrigger for timer tests)
- [ ] Test account credentials valid for target environment
- [ ] Accessibility IDs set on all queried elements
