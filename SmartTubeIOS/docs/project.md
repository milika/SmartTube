# SmartTubeIOS — Project Overview

> Living document. Updated as decisions are made and work is completed.  
> Detailed analysis lives in the numbered docs (`01-` through `05-`); this file is a high-level index and decision log.

---

## What is this project?

**SmartTubeIOS** is an iOS/macOS port of the Android [SmartTube](https://github.com/yuliskov/SmartTube) app — a YouTube client focused on ad-free playback, SponsorBlock, and a clean TV/mobile UI. The iOS implementation is built from scratch in Swift using SwiftUI and Swift Concurrency, mirroring the architecture and API behavior of the Android base project while adopting modern Apple platform idioms.

---

## Repository structure

```
SmartTubeIOS/
├── Package.swift               Swift Package (swift-tools-version: 6.0)
├── Sources/
│   ├── SmartTubeIOSCore/       Foundation-only: models, InnerTubeAPI, SponsorBlock, credentials
│   └── SmartTubeIOS/           SwiftUI UI layer: views, view models, services
├── Tests/
│   └── SmartTubeIOSTests/
├── docs/                       This folder
└── RULES.md                    Agent and contributor rules
```

**Two-target design:**
| Target | Language | Platforms | Purpose |
|--------|----------|-----------|---------|
| `SmartTubeIOSCore` | Swift 6 | iOS 17+, macOS 14+ | Business logic, API, models — no UI |
| `SmartTubeIOS` | Swift 6 | iOS 17+, macOS 14+ | SwiftUI views, AVKit, auth UI |

---

## Technology decisions

### Swift 6 + strict concurrency (decided early)
- `Package.swift` uses `swift-tools-version: 6.0` with `.swiftLanguageVersion(.v6)` on all targets
- All data-race and `Sendable` checks are enabled from the start — no suppression via `@unchecked Sendable` without a documented invariant
- All network work runs in Swift `actor`s (`InnerTubeAPI`, `YouTubeClientCredentialsFetcher`)
- All view-observable state lives in `@MainActor @Observable` classes (no `ObservableObject`/`@Published`/Combine)

### `@Observable` macro over `ObservableObject` (migration complete)
- `AuthService`, `SettingsStore` and all view models use the `@Observable` macro (Swift 5.9+, iOS 17+)
- `import Combine` is absent from all service/view-model files
- The one Combine debounce pipeline in `SearchViewModel` was replaced with `.task(id: query)` + `Task.sleep`

### No Combine, no DispatchQueue in new code
- Network callbacks converted to `async/await` throughout
- `VideoStateStore` (the sole thread-sensitive class not using an actor) uses a serial `DispatchQueue` internally for legacy-compatibility; this is a candidate for actor migration

### Pure SwiftUI + single NavigationStack
- No UIKit views embedded except where required by AVKit
- Navigation is a single `NavigationStack` per screen; sign-in and other modal flows use `.sheet`
- See RULES.md for the constraint: never nest `NavigationStack` inside another

### Single unified Xcode target
- Two separate iOS / macOS targets were merged into one `SmartTube` target using XcodeGen `supportedDestinations: [iOS, iPad, macOS]`
- `project.yml` is the source of truth — never hand-edit `project.pbxproj`

---

## Authentication design

The device authorization grant (RFC 8628) mirrors Android's `YTSignInPresenter` exactly:

1. Scrape `youtube.com/tv` → find `id="base-js"` → fetch the kabuki script → extract `clientId` / `clientSecret` (actor: `YouTubeClientCredentialsFetcher`)
2. `POST /oauth2/device/code` with `client_id`, `client_secret`, `scope` → receive `user_code` + `verification_uri`
3. Show `user_code` on screen; show `https://yt.be/activate` (matches Android's `SIGN_IN_URL`)
4. Generate and display a QR code encoding the verification URL with `?user_code=` pre-filled (CoreImage, zero dependencies)
5. Poll `POST /oauth2/token` every `interval` seconds until approved or expired

**Key rule:** Authenticated InnerTube requests use the **TVHTML5 client context** on `youtubei.googleapis.com` with **no API key** — the Bearer token replaces the key. Unauthenticated requests append `?key=WEB_KEY`. The TV key is dead code (Android's `API_KEY_OLD`) and is never sent.

**Account info fetch:** Uses `POST youtubei.googleapis.com/youtubei/v1/account/accounts` with TVHTML5 context — NOT `/oauth2/v3/userinfo` or YouTube Data API v3 (the TV OAuth client `861556708454` does not have Data API v3 enabled).

**Token storage:** Currently `UserDefaults` (keyed `st_*`). Migration to Keychain (`kSecClassGenericPassword`) is tracked in `05-migration-new-code-rules.md` §1.1 and is required before any public release.

---

## API client design (`InnerTubeAPI`)

Three networking methods, each per-request (no global `URLSession` headers):

| Method | Endpoint | Client context | Auth |
|--------|----------|----------------|------|
| `post()` | `www.youtube.com/youtubei/v1` | WEB (client 1) | none |
| `postPlayer()` | `www.youtube.com/youtubei/v1/player` | iOS (client 5) | none |
| `postTV()` | `youtubei.googleapis.com/youtubei/v1` | TVHTML5 (client 7) | Bearer (no key) or `?key=WEB_KEY` |

The early bug where `URLSession.default.httpAdditionalHeaders` leaked WEB client headers into player requests has been fixed — all headers are set per-request.

---

## Work completed

### Phase 0 — Critical auth fixes (complete)
- ✅ Authenticated browse uses TVHTML5 `postTV()` — aligns with Android's `RetrofitOkHttpHelper`
- ✅ Sign-in URL changed to `yt.be/activate` (matches Android `SIGN_IN_URL`)
- ✅ Global `URLSession` header leak fixed — headers are now per-request
- ✅ `client_secret` added to device/code request body (was missing)

### Phase 1 — Core feature parity (complete)
- ✅ **Watch position tracking** (`VideoStateStore`) — persists per-video position in UserDefaults; restores on next play; prunes to 1,000 entries; mirrors Android's `VideoStateService` behavior (ignores < 5 s, > 95%)
- ✅ **Multi-row home feed** — `fetchHomeRows()` parses `richShelfRenderer` groups into `VideoGroup(layout: .row)`; `BrowseView` renders horizontal `LazyHStack` rows for home, grid for other sections; continuation token support

### Auth quality-of-life fixes (complete)
- ✅ Fallback `client_id` typo fixed (`vc68` → `oc68`)
- ✅ `YouTubeClientCredentialsFetcher` regex updated to match Android's `AppInfo.java` pattern
- ✅ Account name/avatar switched from `/oauth2/v3/userinfo` to `account/accounts` endpoint
- ✅ Sign-in sheet unreachable on iOS fixed (`.sheet` instead of `NavigationLink`)
- ✅ Sign-in loading indicator added (`isLoading` + `ProgressView`)
- ✅ QR code sign-in screen added (`QRCodeView` using `CoreImage`)
- ✅ macOS support — UIKit APIs guarded with `#if os(iOS)`, `NSPasteboard` provided

---

## Work remaining (open tasks)

### Security (before any public release)
- 🔲 **Keychain migration** — move `accessToken`, `refreshToken`, `expiresAt`, `userId` from `UserDefaults` to `SecItem*` Keychain APIs (CWE-312 / OWASP M2) — see `05-migration-new-code-rules.md` §1.1

### `@Observable` migration (Phase 2 of `05-`)
- 🔲 `SettingsStore` — drop `ObservableObject` / `@Published`
- 🔲 `AuthService` — already `@Observable` ✅ (done during auth fixes)
- 🔲 `HomeViewModel` — drop `ObservableObject` / `@Published`
- 🔲 `BrowseViewModel` — drop `ObservableObject` / `@Published`
- 🔲 `SearchViewModel` + `ChannelViewModel` — replace Combine debounce with `.task(id:)` + `Task.sleep`
- 🔲 `PlaybackViewModel` — drop `ObservableObject` / `@Published`

### Missing browse sections
- 🔲 Shorts (`FEshorts`), Music, Sports, Gaming, News, Live, Kids — all present in Android but unimplemented

---

## Reference documents

| File | Content |
|------|---------|
| [01-analysis-android-base-project.md](01-analysis-android-base-project.md) | Deep dive into Android SmartTube architecture, presenters, services |
| [02-analysis-ios-project.md](02-analysis-ios-project.md) | Analysis of the iOS project structure and patterns |
| [03-comparison-android-vs-ios.md](03-comparison-android-vs-ios.md) | Side-by-side diff of every behavioral difference found |
| [04-implementation-plan.md](04-implementation-plan.md) | Phase-by-phase plan; completed phases have detailed "how it was done" notes |
| [05-migration-new-code-rules.md](05-migration-new-code-rules.md) | Migration plan for Swift 6, `@Observable`, and security rules |
| [android-repos.md](android-repos.md) | Links to original Android repos and submodules |
| [../RULES.md](../RULES.md) | Hard rules for agent and contributor behavior |
| [../CHANGELOG.md](../CHANGELOG.md) | Per-release changelog |
