# SmartTubeIOS Changelog

## [Unreleased]

### Added
- **QR code sign-in** — activation screen now shows a QR code encoding the verification URL with `?user_code=` pre-filled so scanning auto-enters the code
- **macOS support** — all iOS-only UIKit APIs guarded with `#if os(iOS)`; `NSPasteboard` used on macOS; semantic SwiftUI colors replace `UIColor`-based ones throughout
- **`CoreImage` QR generator** (`QRCodeView`) — zero-dependency, works on both iOS and macOS

### Fixed
- **Sign-in broken (`deviceCodeRequestFailed`)** — two root causes:
  1. Fallback `client_id` had a one-character typo (`vc68` → `oc68`)
  2. `YouTubeClientCredentialsFetcher` searched for `/base.js` path; YouTube TV now serves credentials from the `id="base-js"` kabuki URL — scraper regex updated to match Android's `AppInfo.java` pattern
- **Account name/avatar not showing after sign-in** — `fetchUserInfo` was calling `/oauth2/v3/userinfo` which requires `openid`/`profile` scopes not requested during sign-in; switched to `GET /youtube/v3/channels?part=snippet&mine=true` which works with the existing YouTube scopes
- **Sign-in sheet unreachable on iOS/iPadOS** — `SettingsView` used a `NavigationLink` to push `SignInView`, but `SignInView` owns its own `NavigationStack`; nested stacks made `dismiss()` a no-op; changed to a `Button` + `.sheet` presentation
- **Sign-in button appeared frozen** — no loading indicator while the two network calls (base.js scrape + device code request) were in flight; added `isLoading` state with a `ProgressView`

### Changed
- **Single unified Xcode target** — two separate targets (iOS + macOS) merged into one `SmartTube` target using XcodeGen `supportedDestinations: [iOS, iPad, macOS]`
- **`AppEntry.swift`** — single `@main` entry; macOS-only `Settings` scene and `.defaultSize` wrapped in `#if os(macOS)`
- **`SearchView`** — removed `.navigationBarDrawer(displayMode:)` placement (unavailable on macOS); `searchable` now uses default placement
