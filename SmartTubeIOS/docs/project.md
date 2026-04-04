# SmartTubeIOS — Project Overview

> Living document. Updated as decisions are made and work is completed.  
> Detailed analysis lives in the numbered docs (`01-` through `05-`); this file is a high-level index and decision log.

---

## What is this project?

**SmartTubeIOS** is a native iOS/macOS YouTube client focused on ad-free playback, SponsorBlock, and a clean mobile/desktop UI. Built from scratch in Swift using SwiftUI and Swift Concurrency, it shares the same YouTube InnerTube API integration and feature goals as the Android-based [SmartTube](https://github.com/yuliskov/SmartTube) app, adapted with idiomatic Apple platform patterns.

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

The device authorization grant (RFC 8628):

1. Scrape `youtube.com/tv` → find `id="base-js"` → fetch the kabuki script → extract `clientId` / `clientSecret` (actor: `YouTubeClientCredentialsFetcher`)
2. `POST /oauth2/device/code` with `client_id`, `client_secret`, `scope` → receive `user_code` + `verification_uri`
3. Show `user_code` and `https://yt.be/activate` on screen
4. Generate and display a QR code encoding the verification URL with `?user_code=` pre-filled (CoreImage, zero dependencies)
5. Poll `POST /oauth2/token` every `interval` seconds until approved or expired

**Key rule:** Authenticated InnerTube requests use the **TVHTML5 client context** on `youtubei.googleapis.com` with **no API key** — the Bearer token replaces the key. Unauthenticated requests append `?key=WEB_KEY`. The TV key (`AIzaSyDCU8...`) is dead code and is never sent.

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
- ✅ Authenticated browse uses TVHTML5 `postTV()` on `youtubei.googleapis.com`
- ✅ Sign-in URL is `yt.be/activate`
- ✅ All `URLSession` headers are per-request (no shared session state)
- ✅ `client_secret` included in device/code request body

### Phase 1 — Core feature parity (complete)
- ✅ **Watch position tracking** (`VideoStateStore`) — persists per-video position in UserDefaults; restores on next play; prunes to 1,000 entries; mirrors Android's `VideoStateService` behavior (ignores < 5 s, > 95%)
- ✅ **Multi-row home feed** — `fetchHomeRows()` parses `richShelfRenderer` groups into `VideoGroup(layout: .row)`; `BrowseView` renders horizontal `LazyHStack` rows for home, grid for other sections; continuation token support
- ✅ **Search filters** — `SearchFilter` model with sort order / upload date / type / duration axes; manual protobuf encoding for InnerTube `params`; filter sheet in `SearchView` with active chip row

### Auth quality-of-life fixes (complete)
- ✅ Fallback `client_id` typo fixed (`vc68` → `oc68`)
- ✅ `YouTubeClientCredentialsFetcher` regex updated to match Android's `AppInfo.java` pattern
- ✅ Account name/avatar switched from `/oauth2/v3/userinfo` to `account/accounts` endpoint
- ✅ Sign-in sheet unreachable on iOS fixed (`.sheet` instead of `NavigationLink`)
- ✅ Sign-in loading indicator added (`isLoading` + `ProgressView`)
- ✅ QR code sign-in screen added (`QRCodeView` using `CoreImage`)
- ✅ macOS support — UIKit APIs guarded with `#if os(iOS)`, `NSPasteboard` provided

### UI Test suite (complete — 26 tests)

All tests live in `SmartTubeApp/UITests/` and run against the `SmartTubeUITests` target.

| Class | Count | Type | What it covers |
|-------|-------|------|----------------|
| `PlaylistsNavigationUITests` | 5 | Navigation (no network) | Library tab → Playlists segment reachable |
| `ShortsNavigationUITests` | 5 | Navigation (no network) | Home tab → Shorts chip reachable |
| `ShortsSwipeUITests` | 9 | Stub (`--uitesting-shorts`) | Swipe up/down, boundary clamping, controls-visible swipe |
| `ShortsLiveSwipeUITests` | 2 | Live (real network) | Open real Short, swipe up/down, boundary |
| `PlayerLiveSwipeUITests` | 5 | Live (real network) | Open real video, swipe left/right, controls-visible swipe |

**Key patterns:**
- `SwipeGestureOverlay` is a UIViewRepresentable (`UIPanGestureRecognizer`) — XCUITest delivers swipes via coordinate-based `press(forDuration:thenDragTo:)`, not `swipeUp()`/`swipeLeft()`
- `shorts.indexLabel` (always-visible badge outside ZStack) is the assertion target for Shorts tests
- `player.titleLabel` (0.01 opacity overlay outside ZStack) is the assertion target for Player tests
- `player.nextBtn` (accessibility identifier on next-track button) is used to poll until `hasNext = true` before performing controls-visible swipe tests
- Live tests use `XCTNSPredicateExpectation` on `video.card.*` descendants with a 20 s timeout; skip with `XCTSkip` if no network

---

## Work remaining (open tasks)

### Phase 3 — Playback enhancements (in progress)
- ✅ **Quality selection dialog** — format list parsed from PlayerInfo; picker sheet in player controls overlay
- ✅ **In-player speed control** — speed picker sheet; persisted in `AppSettings.playbackSpeed`
- ✅ **SponsorBlock per-category actions** — `SponsorBlockAction` enum (skip / showToast / nothing); per-category settings dict in `AppSettings`; `checkSponsorSkip` respects actions; toast tinted with category colour
- ✅ **Swipe navigation — Shorts** — `ShortsPlayerView` uses a `SwipeGestureOverlay` UIViewRepresentable (`UIPanGestureRecognizer`, `cancelsTouchesInView = true`) so gestures fire above `AVPlayerLayerView`; swipe up → next short, swipe down → previous; works when controls are also visible via `.simultaneousGesture(DragGesture)` on the controls overlay
- ✅ **Swipe navigation — Player** — `PlayerView` uses the same `SwipeGestureOverlay` pattern for horizontal left/right swipe; left → `vm.playNext()`, right → `vm.playPrevious()`; `.simultaneousGesture(DragGesture)` on controls overlay ensures it works when controls are shown
- ✅ **AVPlayerLayerView** — both players replaced `VideoPlayer`/`AVPlayerViewController` with a bare `AVPlayerLayer` via `layerClass` override; eliminates UIKit accessibility tree interference that was hiding SwiftUI overlays from XCUITest
- ✅ **Loading spinner** — `ProgressView(.circular, tint: .white, scaleEffect: 1.5)` shown in both players whenever `vm.isLoading` is true; fades in/out with 0.2 s opacity animation
- ✅ **Clean video transition** — `PlaybackViewModel.load(video:)` immediately calls `player.pause()`, `player.replaceCurrentItem(with: nil)`, and resets `isPlaying / currentTime / duration / controlsVisible` before starting the async fetch; old frame is never visible during load; spinner shows over black background
- ✅ **Controls hidden on video start** — `controlsVisible` is reset to `false` and `controlsTimer` is cancelled in `load(video:)` so controls from a previous tap never carry over to the new video
- ✅ **Slide transition animation** — both players animate the swipe gesture live: content follows the finger at 1:1, at boundaries 0.15× rubber-band resistance applies; on confirmed swipe `.easeIn(0.2s)` slides current content off-screen in the swipe direction, the player is cleared, content snaps to the opposite edge, then `.easeOut(0.25s)` slides the new content in; `isTransitioning` guard prevents double-firing from both `SwipeGestureOverlay` and `.simultaneousGesture`; `onPanChanged` / `onSwipeCancelled` callbacks added to `SwipeGestureOverlay` in both player files; `Color.black` background behind the sliding ZStack prevents the home view showing through the gap
- ✅ **Shorts infinite scroll** — `ShortsPlayerView.videos` is now a mutable `@State` array; when `goTo()` reaches within 2 of the end, `loadMoreIfNeeded()` fires a background `fetchShorts()` call, deduplicates by video ID, and appends the new batch; a small bottom-right spinner (`isFetchingMore`) shows during the fetch; if the network is unavailable or no new videos are returned the existing rubber-band boundary behaviour is unchanged
- ✅ **Chapters support** — parse `macroMarkersListItemRenderer` from `/next` response; `Chapter` model in Core (`title`, `startTime`); `chapters` + `currentChapter` on `PlaybackViewModel`; white tick marks on progress bar at each chapter boundary; current chapter title shown above progress bar in player controls overlay
- ✅ **Like/Dislike buttons** — `/like/like`, `/like/dislike`, `/like/removelike` InnerTube endpoints (TVHTML5, Bearer auth); `LikeStatus` enum in Core; `like()` / `dislike()` on `PlaybackViewModel` with optimistic toggle + rollback on failure; `updateAuthToken()` wired via `AuthService` environment; thumbs-up / thumbs-down buttons in player controls top bar (signed-in only; filled + yellow when active)

### `@Observable` migration (Phase 2 of `05-`) — ✅ complete
All view models and services already use `@Observable` + structured concurrency. (Completed incrementally; docs were not updated at the time.)

### Missing browse sections — ✅ complete
Shorts, Music, Gaming, News, Live, Sports are implemented in `InnerTubeAPI` (`fetchShorts`, `fetchMusic`, …) with TVHTML5 browse+search fallback; `BrowseViewModel.fetchSection` handles all `SectionType` cases; sections are listed in `BrowseSection.allSections`.

### Security (before any public release) — ✅ complete
- ✅ **Keychain migration** — `accessToken`, `refreshToken`, `expiresAt`, `accountName`, `accountAvatarURL` stored via `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` in `AuthService` (keys `st_*`, service `com.smarttube.auth`)

---

## Reference documents

| File | Content |
|------|---------|
| [02-analysis-ios-project.md](02-analysis-ios-project.md) | iOS project structure, patterns, and API configuration |
| [04-implementation-plan.md](04-implementation-plan.md) | Phase-by-phase feature plan; completed phases include "how it was done" notes |
| [05-migration-new-code-rules.md](05-migration-new-code-rules.md) | Migration plan for Swift 6, `@Observable`, and security hardening |
| [../RULES.md](../RULES.md) | Hard rules for agent and contributor behavior |
| [../CHANGELOG.md](../CHANGELOG.md) | Per-release changelog |
| **Archive** | |
| [01-analysis-android-base-project.md](01-analysis-android-base-project.md) | *(Archive)* Android SmartTube architecture deep-dive — useful for InnerTube API reference |
| [03-comparison-android-vs-ios.md](03-comparison-android-vs-ios.md) | *(Archive)* Original Android-vs-iOS gap analysis — many gaps listed are now closed |
| [android-repos.md](android-repos.md) | *(Archive)* Links to Android repos for InnerTube/API cross-reference |
