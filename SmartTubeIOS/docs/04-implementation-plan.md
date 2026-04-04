# Implementation Plan — SmartTubeIOS Feature Development

> **Status key:** ✅ Done · 🔲 Not started · 🛧 Partial

## Guiding Principles

1. **Use existing project conventions** — Swift actors, async/await, `@Observable`, `@Environment`
2. **Priority by impact** — fix broken things first, then add missing features
3. **Incremental** — each phase is independently shippable

---

## Phase 0 — Critical Fixes (Auth was broken) ✅ COMPLETE

> These issues prevented core functionality from working correctly.

### 0.1 Fix authenticated browse requests ✅
**Problem:** Authenticated browse requests (subscriptions, history, playlists) were sent via WEB client on `www.youtube.com` with an OAuth Bearer token — the WEB endpoint rejects OAuth tokens with HTTP 400.

**Fix:** Authenticated browse requests use the TVHTML5 client context on `youtubei.googleapis.com` with no `?key=` param (Bearer token replaces the key). Unauthenticated calls use the WEB key.

**How it was done:**
Added `tvClientContext` constant to `InnerTubeAPI`. The TV API key is dead code and never used. Added `postTV(endpoint:body:)` that routes to `youtubei.googleapis.com` with TVHTML5 client/version headers and a `Bearer` auth header. Key logic: `?key=WEB_KEY` only when `authToken == nil` (Bearer replaces key when present). All auth-gated browse methods (`fetchSubscriptions`, `fetchHistory`, `fetchUserPlaylists`, `fetchPlaylistVideos`) and personalised home call `postTV` when `authToken != nil`. `AuthService.fetchUserInfo()` also drops `?key=` since it always has a Bearer token.

### 0.2 Fix sign-in URL ✅
**Problem:** The sign-in screen showed `youtube.com/activate`; the correct short URL is `yt.be/activate`.

**Fix:** Change `verificationURL` fallback and device code response handling to prefer `yt.be/activate`.

**Files:** `AuthService.swift`

**How it was done:**
Changed the hardcoded fallback in `ActivationInfo` from `"https://www.youtube.com/activate"` to `"https://yt.be/activate"`.

### 0.3 Fix URLSession global headers leaking into player requests ✅
**Problem:** `InnerTubeAPI.init()` sets global `URLSessionConfiguration` headers (`X-YouTube-Client-Name: 1`, WEB version) that leak into iOS player requests (which should use client name `5`).

**Fix:** Use a separate URLSession for player requests, or don't set default headers globally — add them per-request in `post()` method.

**Files:** `InnerTubeAPI.swift`

**How it was done:**
Removed all `URLSessionConfiguration.default.httpAdditionalHeaders` assignments from `init()`. All client-specific headers (`X-YouTube-Client-Name`, `X-YouTube-Client-Version`, `Origin`, `User-Agent`) are now set per-request inside each of the three networking methods: `post()`, `postPlayer()`, and `postTV()`.

### 0.4 Add client_secret to device/code request ✅
**Problem:** `requestDeviceCode()` was missing `client_secret` in the request body. The OAuth server requires it.

**Fix:** Add `client_secret` to the device/code form-encoded body.

**Files:** `AuthService.swift`

**How it was done:**
Added `"client_secret=\(credentials.clientSecret)"` to the form body string in `requestDeviceCode()`. Credentials are sourced from `YouTubeClientCredentials` (scraped from `youtube.com/tv` base.js at runtime, falling back to bundled constants).

---

## Phase 1 — Core Features ✅ COMPLETE

### 1.1 Watch position tracking ✅
**Goal:** Persist per-video watch position and percent watched; restore on next play.

**Implementation:**
- Create `VideoStateStore` (similar to `SettingsStore`) that persists `[videoId: (positionSeconds, percentWatched, timestamp)]` in UserDefaults (or a local JSON file)
- In `PlaybackViewModel`: save position on pause/dismiss, restore on load
- In `Video` model: populate `watchProgress` from store when displaying

**Files:** New `VideoStateStore.swift`, modify `PlaybackViewModel.swift`, `Video.swift`

**How it was done:**
Created `Sources/SmartTubeIOSCore/VideoStateStore.swift` — a `final class` singleton with a serial `DispatchQueue` for thread-safety. Stores a `[String: State]` dictionary in `UserDefaults` key `st_video_states` encoded as JSON. Does not persist positions < 5 s or > 95%. Auto-prunes to 1,000 entries by oldest timestamp. In `PlaybackViewModel`:
- `loadAsync()` calls `VideoStateStore.shared.state(for: video.id)` after player info loads; stores the position in `savedPositionToRestore`.
- The `AVPlayerItem.status` observer seeks to `savedPositionToRestore` on `.readyToPlay` (so the item is buffered enough to seek accurately).
- `stop()` calls `VideoStateStore.shared.save(videoId:position:duration:)`.

### 1.2 Home feed — multi-row layout ✅
**Goal:** Parse home feed into named horizontal rows rather than a flat grid.

**Implementation:**
- Parse top-level groups from the `/browse` response (each `richSectionRenderer` or `shelfRenderer` is a group)
- Update `VideoGroup` to support grouping into sections
- Update `BrowseView` to display rows (horizontal ScrollViews) instead of a flat grid for home

**Files:** `InnerTubeAPI.swift` (parser), `BrowseView.swift`, `BrowseViewModel.swift`

**How it was done:**
Added `VideoGroup.Layout` enum (`.grid`, `.row`) and a `layout` property (default `.grid`) to `VideoGroup`. Added `fetchHomeRows(continuationToken:)` to `InnerTubeAPI` — calls `/browse` with `FEwhat_to_watch` and parses each `richShelfRenderer` into a separate `VideoGroup(layout: .row)` via `parseVideoGroupRows()`. Continuation token from `continuationItemRenderer` is attached to the last row. `BrowseViewModel.fetchSection(.home)` now calls `fetchHomeRows()` and assigns the full `[VideoGroup]` array. `BrowseViewModel.fetchNextPage(.home)` calls `fetchHomeRows(continuationToken:)` and appends rows. `BrowseView` checks `group.layout == .row` and renders a new `VideoRowSection` (horizontal `LazyHStack` scroller at 220 pt card width) instead of `VideoGridSection`.

### 1.3 Related videos via metadata ✅
**Goal:** Load related videos from the `/next` endpoint rather than a fallback keyword search.

**Implementation:**
- Add `fetchNextInfo(videoId:)` method calling `/next` endpoint with WEB client
- Parse related video renderers from the response
- Display in `PlayerView` below the player (or in a sheet)

**Files:** `InnerTubeAPI.swift`, `PlaybackViewModel.swift`, `PlayerView.swift`

**How it was done:**
Added `fetchNextInfo(videoId:) async throws -> [Video]` to `InnerTubeAPI`. Posts to the WEB `/next` endpoint with the `videoId`. Parses `compactVideoRenderer` objects anywhere in the response tree via a recursive `parseRelatedVideos(from:)` walker; returns up to all found (caller trims to 25). `PlaybackViewModel.loadAsync()` now calls `fetchNextInfo` first; falls back to `search(query: info.video.title)` if the result is empty (e.g. network restriction). Self-video is filtered out of results.

### 1.4 Search filters ✅
**Goal:** Support sort order, upload date, type, and duration filter axes.

**Files:** `InnerTubeAPI.swift`, `SearchViewModel.swift`, `SearchView.swift`, new `SearchFilter` model

**How it was done:**
Added `SearchFilter` struct to `SmartTubeIOSCore` with four filter axes:
- `SortOrder` (relevance / rating / upload date / view count)
- `UploadDate` (anytime / last hour / today / this week / this month / this year)
- `VideoType` (any / video / channel / playlist / movie)
- `Duration` (any / short <4min / medium 4-20min / long >20min)

`SearchFilter.encodedParams()` manually encodes the active filters into the base64 protobuf string consumed by InnerTube's `params` field (no external proto library required).

`InnerTubeAPI.search()` gains an optional `filter: SearchFilter = .default` parameter; the encoded param is injected into the request body when active.

`SearchViewModel` gains a `filter: SearchFilter` property and `applyFilter(_:)` — applies a new filter and immediately re-runs the search.

`SearchView` gains:
- A filter button (funnel icon, highlighted when non-default) in the search bar that opens `SearchFilterSheet`.
- A horizontal chip row below the search bar showing each active filter with an inline ×-remove tap target.
- `SearchFilterSheet` — a `.sheet` with inline Pickers for each filter axis, plus Apply / Cancel / Reset toolbar buttons.

### 1.5 Video context menu (long-press) ✅
**Goal:** Long-press on a video card shows a context menu with Share and Open Channel actions.

**Implementation:**
- Add `.contextMenu` modifier to `VideoCardView`
- Include: Play, Open Channel, Share (system share sheet)

**Files:** `VideoCardView.swift`

**How it was done:**
Added a `.contextMenu` modifier wrapping both `gridLayout` and `compactLayout` via a `Group`. Two actions:
- **Share** — `ShareLink(item: URL("https://www.youtube.com/watch?v=\(video.id)"))` using native system share sheet.
- **Open Channel** — posts `Notification.Name.openChannel` (defined in the same file) with `channelId` + `channelTitle` in `userInfo`; only shown when `video.channelId` is non-empty. Channel navigation is handled via `NotificationCenter` rather than deep-linking through `NavigationPath` to keep `VideoCardView` decoupled from nav stack.

---

## Phase 2 — Missing Browse Sections

> Add browse sections that were absent from the initial release.

### 2.1 Add missing browse sections
Add support for additional feed sections:

| Section | Browse ID / Method | Layout |
|---------|-------------------|--------|
| Shorts | `FEshorts` / `fetchShorts()` | Grid |
| Music | Music browse | Row |
| Gaming | Gaming browse | Row |
| News | News browse | Row |
| Live | Live browse | Row |
| Sports | Sports browse | Row |
| My Videos | `FEmy_videos` | Grid |
| Notifications | Notifications API | Grid |

**Implementation:**
- Add browse IDs and fetch methods to `InnerTubeAPI`
- Add section types to `BrowseSection.SectionType`
- Add to `defaultSections` (or make sections configurable)
- Add loading logic to `BrowseViewModel`

**Files:** `InnerTubeAPI.swift`, `VideoGroup.swift` (BrowseSection), `BrowseViewModel.swift`, `BrowseView.swift`

### 2.2 Configurable sections (sidebar toggle)
**Android:** `SidebarService` allows enabling/disabling and reordering sections.

**Implementation:**
- Add `enabledSections: [SectionType]` to `AppSettings`
- Add section management UI in Settings
- Use ordered list to determine sidebar/tab order

**Files:** `AppSettings.swift`, `SettingsView.swift`, `BrowseViewModel.swift`

---

## Phase 3 — Playback Enhancements

### 3.1 Quality selection dialog
**Android:** `HQDialogController` shows available formats and lets user pick quality.

**Implementation:**
- Parse available formats from `PlayerInfo.formats`
- Add a quality picker button in player controls overlay
- Show sheet/popover with format options
- When user picks a format → reload AVPlayerItem with that format's URL (for progressive) or adjust HLS preference

**Files:** `PlayerView.swift`, `PlaybackViewModel.swift`

### 3.2 In-player speed control
**Android:** Speed can be changed in-player via dialog.

**Implementation:**
- Add speed picker button to player controls overlay
- Apply via `player.rate = speed`

**Files:** `PlayerView.swift`, `PlaybackViewModel.swift`

### 3.3 SponsorBlock — color-coded markers + per-category actions ✅
**Android:** Each SB category has its own color and action (skip/toast/dialog/nothing).

**Implementation:**
- Add color mapping to `SponsorSegment.Category` (matching Android's color scheme)
- Add per-category action setting to `AppSettings`
- Update progress bar markers to use category-specific colors
- Add "Don't skip this again" option

**Files:** `AppSettings.swift`, `PlayerView.swift`, `PlaybackViewModel.swift`, `SettingsView.swift`

**How it was done:**
Added `SponsorBlockAction` enum (`.skip`, `.showToast`, `.nothing`) to `AppSettings` and replaced the old `sponsorBlockCategories: Set<SponsorSegment.Category>` with `sponsorBlockActions: [SponsorSegment.Category: SponsorBlockAction]` (defaults mirror Android's `SponsorBlockData`: sponsor/selfPromo → auto-skip; interaction/intro/preview/musicOfftopic → show toast; others → nothing). Computed `activeSponsorCategories` drives which categories are fetched from the API.

`PlaybackViewModel.checkSponsorSkip(at:)` now respects the per-category action:
- `.skip` → auto-seeks past the segment (previous behaviour)
- `.showToast` → sets `currentToastSegment` (new observable property) so the view can render a skip button; segment is cleared when the playhead exits
- `.nothing` → no action

`skipToastSegment()` added for the view to call when the user taps the skip button.

`PlayerView.sponsorSkipToast` now drives from `vm.currentToastSegment` instead of scanning `vm.sponsorSegments` itself; the button label reads "Skip {category}" and is tinted with the category's canonical color.

`SponsorBlockColors.swift` gained `displayName` (moved from a private `SettingsView` extension) so it's accessible across all views in the module.

`SettingsView.sponsorBlockSection` replaced category Toggles with a three-option `Picker` (Skip / Show Toast / Nothing) per category, each prefixed with a colour dot.

### 3.4 Chapters support
**Android:** Chapters parsed from video metadata, shown as markers on progress bar.

**Implementation:**
- Parse chapter data from `/next` or `/player` response (chapters are in `videoDetails.chapters`)
- Display chapter markers on progress bar
- Show chapter title during seek

**Files:** `InnerTubeAPI.swift`, `PlaybackViewModel.swift`, `PlayerView.swift`

### 3.5 Like/Dislike buttons
**Android:** MediaItemService handles like/dislike toggling.

**Implementation:**
- Add `/like` and `/dislike` InnerTube endpoints
- Add like/dislike buttons to player controls
- Show current like/dislike counts from video metadata

**Files:** `InnerTubeAPI.swift`, `PlayerView.swift`, `PlaybackViewModel.swift`

---

## Phase 4 — Settings Alignment

### 4.1 Player settings expansion
Add missing player settings following Android's `PlayerData`:
- Controls auto-hide timeout
- Resize/zoom mode
- Seek increments (configurable forward/back)
- Sleep timer
- Playback mode (loop, shuffle)

**Files:** `AppSettings.swift`, `SettingsView.swift`

### 4.2 General settings expansion
Following Android's `GeneralData`:
- History state control (auto/enabled/disabled)
- Background playback shortcut behavior

**Files:** `AppSettings.swift`, `SettingsView.swift`

### 4.3 Search settings
Following Android's `SearchData`:
- Search history toggle
- Voice search (iOS Speech framework)

**Files:** `AppSettings.swift`, `SettingsView.swift`, `SearchViewModel.swift`

### 4.4 SponsorBlock settings expansion
Following Android's `SponsorBlockData`:
- Per-category action selection
- Excluded channels list
- Minimum segment duration filter
- Add missing `poi_highlight` category

**Files:** `AppSettings.swift`, `SettingsView.swift`

---

## Phase 5 — Advanced Features

### 5.1 Multi-account support
**Android:** `AccountSelectionPresenter` manages multiple Google accounts.

**Implementation:**
- Extend `AuthService` to store multiple account credentials
- Add account switcher in Settings
- On switch → update auth token → reload content

### 5.2 Playback queue
**Android:** `Playlist.java` manages a local playback queue.

**Implementation:**
- Create `PlaybackQueue` ObservableObject
- Add "Add to Queue" in video context menu
- Show queue as a section
- Auto-play next from queue

### 5.3 Blocked channels
**Android:** `BlockedChannelData` manages blocked channels.

**Implementation:**
- Store blocked channel IDs in settings
- Filter videos from blocked channels in all feeds
- Add block/unblock to video context menu

### 5.4 Pinned sections
**Android:** Pin channels/playlists to sidebar.

**Implementation:**
- Allow long-press on channels/playlists → "Pin to Sidebar"
- Store pinned items
- Show as additional sections

### 5.5 Subscribe/Unsubscribe
Add InnerTube `/subscription/subscribe` and `/subscription/unsubscribe` endpoints.

### 5.6 Share video
Add system share sheet with YouTube URL.

---

## Phase 6 — Persistence & Security Upgrades

### 6.1 Keychain migration
**Current:** Tokens stored in UserDefaults (insecure).
**Fix:** Migrate to Keychain using Security framework.

### 6.2 Watch history persistence
Use a local database (SwiftData or JSON file) for watch history and video state.

---

## Implementation Order (Recommended)

```
Phase 0 (Critical):    0.1 → 0.3 → 0.2 → 0.4
Phase 1 (Core):        1.1 → 1.3 → 1.2 → 1.5 → 1.4
Phase 2 (Sections):    2.1 → 2.2
Phase 3 (Playback):    3.2 → 3.1 → 3.3 → 3.5 → 3.4
Phase 4 (Settings):    4.4 → 4.1 → 4.2 → 4.3
Phase 5 (Advanced):    5.6 → 5.3 → 5.2 → 5.1 → 5.5 → 5.4
Phase 6 (Security):    6.1 → 6.2
```

---

## Files Impact Summary

| File | Changes Needed |
|------|---------------|
| `InnerTubeAPI.swift` | TVHTML5 auth'd requests, /next endpoint, search filters, new browse IDs, like/dislike/subscribe, chapters |
| `AuthService.swift` | client_secret in device/code, sign-in URL fix |
| `Video.swift` | Add missing fields (startTimeSeconds, deArrowTitle, percentWatched persistence, etc.) |
| `VideoGroup.swift` | Multi-row home support, additional section types, REMOVE_AUTHOR/SYNC actions |
| `AppSettings.swift` | Many new settings (per-category SB actions, player tweaks, search, general) |
| `BrowseViewModel.swift` | New sections, multi-row home, configurable section order |
| `PlaybackViewModel.swift` | Watch state, quality picker, speed control, chapters, related via /next |
| `SearchViewModel.swift` | Search filters, search history |
| `BrowseView.swift` | Multi-row home layout, new section UI |
| `PlayerView.swift` | Quality picker, speed control, chapters overlay, like/dislike, color-coded SB |
| `SearchView.swift` | Filter UI |
| `SettingsView.swift` | Many new settings sections |
| `VideoCardView.swift` | Context menu, deArrow title |
| New: `VideoStateStore.swift` | Watch position persistence |
| New: `PlaybackQueue.swift` | Playback queue management |
