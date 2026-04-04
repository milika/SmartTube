# iOS SmartTubeIOS Project — Analysis

## Architecture Overview

```
┌──────────────────────────────────────┐
│  SmartTubeApp.swift (@main)          │  App entry point
├──────────────────────────────────────┤
│  Views (SwiftUI)                     │  RootView, BrowseView, PlayerView,
│                                      │  SearchView, SignInView, SettingsView,
│                                      │  LibraryView, ChannelView, VideoCardView
├──────────────────────────────────────┤
│  ViewModels (@MainActor)             │  BrowseViewModel, PlaybackViewModel,
│                                      │  SearchViewModel, ChannelViewModel
├──────────────────────────────────────┤
│  Services                            │  AuthService, SettingsStore
├──────────────────────────────────────┤
│  SmartTubeIOSCore (Foundation-only)  │  InnerTubeAPI (actor), Video, VideoGroup,
│                                      │  AppSettings, SponsorBlockService,
│                                      │  DeArrowService, YouTubeClientCredentials
└──────────────────────────────────────┘
```

**Targets:**
- `SmartTubeIOSCore` — Foundation-only, no UI
- `SmartTubeIOS` — SwiftUI, Apple platforms only (iOS 17+, macOS 14+)

---

## Key Design Patterns

### 1. Actor-based API Client

```swift
public actor InnerTubeAPI {
    private var authToken: String?
    public func setAuthToken(_ token: String?) { ... }
    public func fetchHome(...) async throws -> VideoGroup { ... }
    // etc.
}
```

- Thread-safe via Swift actor isolation
- All methods are `async throws`
- No RxJava/Combine — pure async/await

### 2. @Observable ViewModels

```swift
@MainActor public final class BrowseViewModel {
    var videoGroups: [VideoGroup] = []
    var isLoading = false
    private let api = InnerTubeAPI()
    
    func loadContent(for section: BrowseSection?, refresh: Bool) { ... }
}
```

### 3. Environment Dependency Injection

```swift
// SmartTubeApp.swift
@State private var authService = AuthService()
@State private var browseViewModel = BrowseViewModel()

var body: some Scene {
    WindowGroup {
        RootView()
            .environment(authService)
            .environment(browseViewModel)
            .onChange(of: authService.accessToken) { _, newToken in
                Task { await browseViewModel.updateAuthToken(newToken) }
            }
    }
}
```

### 4. Keychain / UserDefaults Persistence

- `AuthService` stores OAuth tokens in Keychain (`kSecClassGenericPassword`, service `com.smarttube.auth`, keys `st_*`)
- `SettingsStore` stores JSON-encoded `AppSettings` in UserDefaults (key: `smarttube_app_settings`)

---

## Source Files

### Core Layer (SmartTubeIOSCore)

| File | Lines | Purpose |
|------|-------|---------|
| `InnerTubeAPI.swift` | ~553 | Complete InnerTube client (browse, search, player, playlists, channels) |
| `Video.swift` | ~100 | Video model (Identifiable, Hashable, Codable) |
| `VideoGroup.swift` | ~200 | VideoGroup, BrowseSection, SearchResult, Channel, PlaylistInfo, VideoFormat, SponsorSegment models |
| `AppSettings.swift` | ~100 | Settings model (Codable) — quality, speed, SB, DeArrow, theme |
| `YouTubeClientCredentials.swift` | ~200 | Scrapes YouTube TV base.js for OAuth credentials |
| `SponsorBlockService.swift` | ~100 | SponsorBlock + DeArrow API clients |

### UI Layer (SmartTubeIOS)

| File | Lines | Purpose |
|------|-------|---------|
| `SmartTubeApp.swift` | ~20 | @main entry, DI setup |
| `AuthService.swift` | ~450 | OAuth Device Authorization Grant flow |
| `SettingsStore.swift` | ~30 | Auto-persisting settings wrapper |
| `BrowseViewModel.swift` | ~180 | Browse feed logic (home, subs, history, playlists, channels) |
| `PlaybackViewModel.swift` | ~300 | Video playback (AVPlayer, SponsorBlock, formats) |
| `SearchViewModel.swift` | ~120 | Search + suggestions + channel VM |
| `RootView.swift` | ~100 | Root layout (TabView on iOS, NavigationSplitView on macOS) |
| `BrowseView.swift` | ~180 | Home feed grid with section picker |
| `PlayerView.swift` | ~400 | Video player with controls overlay |
| `SearchView.swift` | ~120 | Search results view |
| `SignInView.swift` | ~400 | Sign-in flow with QR code |
| `SettingsView.swift` | ~140 | Settings form |
| `LibraryView.swift` | ~180 | Library (subs, history, playlists) |
| `ChannelView.swift` | ~150 | Channel page |
| `VideoCardView.swift` | ~180 | Video card (grid + compact layouts) |

### Tests

| File | Tests | Coverage |
|------|-------|----------|
| `SmartTubeIOSTests.swift` | 14 tests | Video model, VideoGroup, AppSettings, SponsorSegment, VideoFormat, JSON parser (subscriptions/home mock) |

---

## API Configuration (iOS)

### Client Contexts
| Client | Name | Version | Use Case | Base URL |
|--------|------|---------|----------|----------|
| WEB | `"WEB"` | `2.20260206.01.00` | Browse, search, home | `www.youtube.com/youtubei/v1` |
| iOS | `"iOS"` | `20.11.6` | Stream URLs (HLS) | `youtubei.googleapis.com/youtubei/v1` |
| TVHTML5 | `"TVHTML5"` | `7.20230405.08.01` | Authenticated browse, account info | `youtubei.googleapis.com/youtubei/v1` |

### API Keys
| Key | Value | Use |
|-----|-------|-----|
| WEB | `AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8` | All unauthenticated requests (`?key=`) |
| TV | `AIzaSyDCU8hByM-4DrUqRUYnGn-3llEO78bcxq8` | **Not used** — Bearer token replaces key when authenticated |

### OAuth
- Device Authorization Grant (RFC 8628)
- Credentials scraped at runtime from `youtube.com/tv` base.js; bundled fallback credentials kept up to date
- Scope: `"http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"`
- Sign-in URL: `yt.be/activate`

---

## InnerTubeAPI Methods

| Method | Uses | Auth | Continuation |
|--------|------|------|-------------|
| `fetchHome(continuationToken:)` | WEB `/browse` (`FEwhat_to_watch`) | Optional | ✅ |
| `fetchSubscriptions(continuationToken:)` | WEB `/browse` (`FEsubscriptions`) | Required | ✅ |
| `fetchHistory(continuationToken:)` | WEB `/browse` (`FEhistory`) | Required | ✅ |
| `search(query:continuationToken:)` | WEB `/search` | Optional | ✅ |
| `fetchSearchSuggestions(query:)` | GET suggestqueries | No | N/A |
| `fetchChannel(channelId:)` | WEB `/browse` | No | ❌ |
| `fetchChannelVideos(channelId:continuationToken:)` | WEB `/browse` | No | ✅ |
| `fetchPlayerInfo(videoId:)` | iOS `/player` | No | N/A |
| `fetchUserPlaylists()` | WEB `/browse` (`FEmy_videos`) | Required | ❌ |
| `fetchPlaylistVideos(playlistId:continuationToken:)` | WEB `/browse` (`VL{id}`) | Optional | ✅ |

---

## Video Model (iOS)

```swift
public struct Video: Identifiable, Hashable, Codable {
    public let id: String                    // videoId
    public var title: String
    public var channelTitle: String
    public var channelId: String?
    public var description: String?
    public var thumbnailURL: URL?
    public var duration: TimeInterval?       // seconds
    public var viewCount: Int?
    public var publishedAt: Date?
    public var isLive: Bool
    public var isUpcoming: Bool
    public var isShort: Bool
    public var watchProgress: Double?        // resume position (NOT persisted)
    public var playlistId: String?
    public var playlistIndex: Int?
    public var badges: [String]
}
```

**Computed properties:** `formattedDuration`, `formattedViewCount`, `highQualityThumbnailURL`

---

## VideoGroup Model (iOS)

```swift
public struct VideoGroup: Identifiable {
    public let id: UUID
    public var title: String?
    public var videos: [Video]
    public var nextPageToken: String?
    public var action: Action = .append      // .append, .replace, .remove, .prepend
}
```

---

## BrowseSection (iOS)

```swift
public struct BrowseSection: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let type: SectionType
    
    public enum SectionType: String, CaseIterable, Codable {
        case home, subscriptions, history, playlists, channels
        case shorts, music, news, gaming, settings
    }
    
    public static let defaultSections: [BrowseSection] = [
        .init(id: "home", title: "Home", type: .home),
        .init(id: "subscriptions", title: "Subscriptions", type: .subscriptions),
        .init(id: "history", title: "History", type: .history),
        .init(id: "playlists", title: "Playlists", type: .playlists),
        .init(id: "channels", title: "Channels", type: .channels),
    ]
}
```

---

## AppSettings (iOS)

```swift
public struct AppSettings: Codable {
    public var preferredQuality: VideoQuality = .auto     // auto..q4320
    public var playbackSpeed: Double = 1.0
    public var autoplayEnabled: Bool = true
    public var subtitlesEnabled: Bool = false
    public var backgroundPlaybackEnabled: Bool = false
    public var defaultSection: String = "home"
    public var compactThumbnails: Bool = false
    public var hideShorts: Bool = false
    public var themeName: ThemeName = .system
    public var sponsorBlockEnabled: Bool = true
    public var sponsorBlockCategories: Set<SponsorSegment.Category>
    public var deArrowEnabled: Bool = false
}
```

---

## Authentication Flow (iOS)

1. `AuthService.beginSignIn()` → fetch TV credentials from base.js
2. POST `https://oauth2.googleapis.com/device/code` → get user_code + verification_url
3. Show QR code + user_code on `SignInView`
4. Poll `https://oauth2.googleapis.com/token` (grant_type: `http://oauth.net/grant_type/device/1.0`)
5. On success → store tokens → fetch user info via TVHTML5 `/account/accounts`
6. Token refresh via `validAccessToken()` → POST `/token?grant_type=refresh_token`
