# SmartTube iOS

A SwiftUI port of the [SmartTube](https://github.com/yuliskov/SmartTube) Android TV YouTube client, targeting **iPhone**, **iPad**, and **macOS** (Catalyst / native macOS 13+).

> **tvOS is intentionally out of scope.**  
> The Android TV Leanback UI is not replicated; instead a native SwiftUI adaptive layout is used.

---

## Feature Parity

| Android Feature | iOS Implementation |
|---|---|
| Home / Subscriptions / History feeds | `BrowseView` + `BrowseViewModel` → InnerTube API |
| Video playback (adaptive, HLS, DASH) | `PlayerView` + `PlaybackViewModel` → AVPlayer / AVKit |
| Search with suggestions | `SearchView` + `SearchViewModel` |
| Channel browser | `ChannelView` + `ChannelViewModel` |
| SponsorBlock auto-skip | `SponsorBlockService` + segment markers on progress bar |
| DeArrow community titles/thumbnails | `DeArrowService` |
| Google OAuth sign-in | `AuthService` via `ASWebAuthenticationSession` |
| Settings (quality, speed, theme, SponsorBlock categories) | `SettingsView` + `SettingsStore` |
| Library (playlists, history) | `LibraryView` |
| Picture-in-Picture | Built-in via `AVKit.VideoPlayer` |

---

## Architecture

```
SmartTubeIOS/
├── Package.swift
└── Sources/SmartTubeIOS/
    ├── SmartTubeApp.swift          # @main entry point
    ├── Models/
    │   ├── Video.swift             # Core video data model
    │   ├── VideoGroup.swift        # VideoGroup, BrowseSection, Channel, etc.
    │   └── AppSettings.swift       # Persisted user preferences
    ├── Services/
    │   ├── InnerTubeAPI.swift      # YouTube InnerTube API (unofficial)
    │   ├── SponsorBlockService.swift  # SponsorBlock + DeArrow APIs
    │   ├── AuthService.swift       # Google OAuth 2.0
    │   └── SettingsStore.swift     # UserDefaults-backed preferences store
    ├── ViewModels/
    │   ├── BrowseViewModel.swift   # Home/subs feeds
    │   ├── PlaybackViewModel.swift # AVPlayer wrapper + SponsorBlock skip
    │   └── SearchViewModel.swift   # Search + ChannelViewModel
    └── Views/
        ├── RootView.swift          # iOS TabView / macOS SidebarView
        ├── Browse/
        │   ├── BrowseView.swift    # Main grid feed
        │   └── VideoCardView.swift # Thumbnail card (grid & compact)
        ├── Player/
        │   └── PlayerView.swift    # Full-screen AVKit player + controls
        ├── Search/
        │   └── SearchView.swift    # Searchable results list
        ├── Channel/
        │   └── ChannelView.swift   # Channel header + video grid
        ├── Settings/
        │   └── SettingsView.swift  # App preferences Form
        └── Common/
            ├── SignInView.swift    # Google sign-in sheet
            └── LibraryView.swift   # Subscriptions / History / Playlists
```

### Design Patterns

| Android | iOS Port |
|---|---|
| MVP (Presenter / View / Model) | **MVVM** (`@StateObject` / `@EnvironmentObject` ViewModels) |
| RxJava / RxAndroid | **Combine** + Swift **async/await** |
| Leanback Fragment navigation | **NavigationStack** + `TabView` (iOS) / `NavigationSplitView` (macOS) |
| ExoPlayer | **AVPlayer** + AVKit `VideoPlayer` |
| Glide image loading | **AsyncImage** (SwiftUI built-in) |
| SharedPreferences | **UserDefaults** via `SettingsStore` |
| Google OAuth (WebView flow) | **ASWebAuthenticationSession** |

---

## Requirements

| Platform | Minimum Version |
|---|---|
| iOS / iPadOS | 16.0 |
| macOS | 13.0 (Ventura) |

Xcode 15+ is required to build the project.

---

## Getting Started

### 1. Open in Xcode

```bash
open SmartTubeIOS/Package.swift
```

Or add the `SmartTubeIOS` folder as a local Swift Package to an `.xcodeproj`.

### 2. Configure Google OAuth

1. Create a project at <https://console.cloud.google.com/apis/credentials>.
2. Add an **iOS** OAuth 2.0 client ID.
3. Register the custom URL scheme `smarttube` in your app's Info.plist.
4. Replace `YOUR_GOOGLE_CLIENT_ID` in `AuthService.swift` with your client ID.

### 3. Run Tests

```bash
swift test --package-path SmartTubeIOS
```

---

## Notes

- The [InnerTube API](https://github.com/LuanRT/YouTube.js) used here is **unofficial** and may break when YouTube updates its backend.  The Android SmartTube project uses the same API via `MediaServiceCore`.
- Stream URLs returned by the InnerTube player endpoint are time-limited; long-running downloads will require re-fetching.
- Background audio playback requires the `audio` background mode to be added to the app's Info.plist.
- For production use, replace the `UserDefaults`-backed token storage in `AuthService` with `Keychain`.
