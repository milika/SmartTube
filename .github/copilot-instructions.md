# GitHub Copilot Instructions

## Swift Code Changes
- **All `.swift` file edits must follow the rules in `.github/swift.instructions.md`** — covering language version, code style, SwiftUI, concurrency, error handling, memory management, testing, documentation, networking, security, and deprecated patterns.
- **For concurrency-related work** (async/await, actors, tasks, Sendable, `@MainActor`, Swift 6 migration, data races, linting warnings) — load and follow `.github/skills/swift-concurrency/SKILL.md` via the `swift-concurrency` agent skill before advising or making changes.
- When adding or modifying public APIs, add DocC-style `///` documentation comments.
- Never introduce completion handlers, `DispatchQueue`, `ObservableObject`+`@Published`, or force unwrapping in new Swift code.

## Xcode interactions
- **All Xcode interactions must go through the Xcode MCP tools** (`mcp_xcode_*`).
- Do **not** use `xcodebuild`, `xcrun simctl`, `xcode-select`, `instruments`, `xcrun`, or any other CLI or scripting mechanism to build, run, test, sign, or inspect the Xcode project.
- If an `mcp_xcode_*` tool is unavailable for a specific task (e.g. monitoring runtime logs/console output), **instruct the user to use Xcode directly** (e.g. open the Debug Console pane in Xcode) rather than falling back to the command line.
- **Exception: read-only log streaming** (`xcrun simctl spawn booted log stream`) is permitted via the terminal when no MCP tool covers it.
