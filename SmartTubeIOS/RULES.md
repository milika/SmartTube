# SmartTubeIOS — Development Rules

## Agent behaviour
- **Do not change app general info** (bundle ID, display name, version, deployment target, signing settings, URL schemes, `Info.plist` properties) unless the user explicitly asks for it
- **Do not restructure the project** (rename targets, move source folders, change `project.yml` top-level settings) unless explicitly requested
- **All Xcode interactions must go through the Xcode MCP tools** (`mcp_xcode_*`). Do not use `xcodebuild`, `xcrun simctl`, `xcode-select`, or any other CLI/scripting mechanism to build, run, test, or inspect the Xcode project. If an Xcode MCP tool is unavailable for a task (e.g. monitoring runtime logs), instruct the user to use Xcode directly (e.g. open the Debug Console pane in Xcode) rather than falling back to the command line. **Exception:** read-only log streaming (`xcrun simctl spawn booted log stream`) is permitted via the terminal.
- **Always target the iPhone 17 simulator (UDID `2CBB1CF2-D0EF-4CBB-B43E-1B728B3C0415`)** for building, running, and log capture — it has a Google account already signed in, enabling authenticated endpoint testing (subscriptions, history).

## Platform compatibility
- All code in `SmartTubeIOS` (UI layer) must compile on **iOS 17+, iPadOS 17+, and macOS 14+**
- UIKit-only APIs (`UIColor`, `UIPasteboard`, `.navigationBarHidden`, `.statusBarHidden`, `.toolbar(.hidden, for: .tabBar)`, `.navigationBarTitleDisplayMode`) must be wrapped in `#if os(iOS)`
- AppKit equivalents (`NSPasteboard`, `NSImage`) must be provided in `#else` branches
- Use SwiftUI semantic colors (`.background`, `.secondary`, `Color.secondary.opacity(...)`) instead of `UIColor`/`NSColor` system color initializers — they resolve correctly on all platforms

## SwiftUI navigation
- Never nest a `NavigationStack` inside another `NavigationStack` — use `.sheet`, `.fullScreenCover`, or a single stack with `navigationDestination`
- Sign-in is presented as a **sheet** (not a `NavigationLink` push) so `dismiss()` works correctly

## OAuth / authentication (`AuthService`)
- The device authorization grant uses the **YouTube TV client credentials** scraped from `youtube.com/tv`
- The `id="base-js"` element in the TV HTML points to the kabuki `/m=base` script that contains `clientId`/`clientSecret` — match Android's `AppInfo.java` regex exactly: `id="base-js" src="([^"]+)"`
- The fallback credentials (`YouTubeClientCredentialsFetcher.fallback`) must be kept up to date with the live `client_id` from `base-js`
- **Do not** call `/oauth2/v3/userinfo` or `youtube/v3/channels` for account info — the TV OAuth credentials (`861556708454`) do not have YouTube Data API v3 enabled; use `POST youtubei.googleapis.com/youtubei/v1/account/accounts` with the TVHTML5 client context instead
- **Authenticated InnerTube requests** (subscriptions, history) must use the **TVHTML5 client context** on `youtubei.googleapis.com` with **no API key** — the OAuth Bearer token replaces the key, matching Android's `RetrofitOkHttpHelper` behavior (`authHeaders` non-empty → skip key, apply Bearer). Unauthenticated requests (including unauthenticated TV-client calls like trending) append `?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8` (WEB key). The TV key (`AIzaSyDCU8hByM-4DrUqRUYnGn-3llEO78bcxq8`) is defined in Android as `API_KEY_OLD` and is never used. The WEB client on `www.youtube.com` rejects OAuth Bearer tokens (returns 400).
- Tokens are stored in `UserDefaults` (keyed with `st_*` prefixes); migrate to Keychain before any public release

## Project structure
- `SmartTubeIOSCore` — Foundation-only, no SwiftUI/UIKit
- `SmartTubeIOS` — SwiftUI UI layer (Apple platforms only)
- One XcodeGen target (`SmartTube`) with `supportedDestinations: [iOS, iPad, macOS]`; no separate macOS target
- `project.yml` is the source of truth — always run `xcodegen generate` after editing it, never hand-edit `project.pbxproj`

## Icon / assets
- `AppIcon.appiconset` lives at `SmartTubeApp/SmartTubeApp/Assets.xcassets/AppIcon.appiconset`
- Source icon is `smarttubetv/src/main/res/mipmap-nodpi/app_icon.png`; resize with `sips` when updating
- `Contents.json` must cover all iOS (iPhone + iPad) and macOS icon slots

## Code style
- No force-unwraps except in clearly impossible cases (document why)
- `@MainActor` on all `ObservableObject` view-models
- Prefer `async/await` over Combine or callback chains for new network code
- Log with `os.Logger` (subsystem `com.smarttube.app`) — use `.notice` for milestones, `.error` for failures, `.debug` for polling loops
