# Comparison: Android Base vs iOS Implementation

## Summary

The iOS port covers the core functionality but diverges from the Android project's methodology in several important areas. This document catalogs every discrepancy.

---

## 1. AUTH FLOW DIFFERENCES

### 1.1 Sign-in URL
| | Android | iOS |
|-|---------|-----|
| URL | `https://yt.be/activate` | `https://youtube.com/activate` |
| **Impact** | `yt.be/activate` — shorter, used in YTSignInPresenter | Different URL shown to user |

### 1.2 OAuth Scope
| | Android | iOS |
|-|---------|-----|
| Scope | Appears to use YouTube-only scope | `"http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"` |
| **Impact** | Need to verify exact Android scope from MediaServiceCore submodule |

### 1.3 Device Code Request — client_secret
| | Android | iOS |
|-|---------|-----|
| Sends client_secret | Yes (in device/code request) | No — only sends `client_id` and `scope` |
| **Impact** | Some OAuth servers accept without client_secret but this diverges from Android behavior |

### 1.4 Auth Token Usage for Browse Requests ✅ ALIGNED
| | Android | iOS |
|-|---------|-----|
| Auth'd browse (subs, history) | **TVHTML5 client** on `youtubei.googleapis.com`, **no ?key=** (Bearer replaces key) | **TVHTML5 client** on `youtubei.googleapis.com`, **no ?key=** (Bearer replaces key) |
| Unauthenticated requests | WEB key as `?key=` | WEB key as `?key=` |
| TV key usage | `API_KEY_OLD` — never used in any request | Removed — never used |

### 1.5 Credential Fetcher Architecture
| | Android | iOS |
|-|---------|-----|
| Class | Described in RULES.md as `AppInfo.java` | `YouTubeClientCredentialsFetcher` (actor) |
| Pattern | Matches `id="base-js" src="([^"]+)"` | Same regex pattern |
| **Status** | ✅ Aligned |

---

## 2. API CLIENT DIFFERENCES

### 2.1 Authenticated Requests Architecture ✅ ALIGNED
**Android:** Authenticated requests (subscriptions, history, playlists) use **TVHTML5 client context** on `youtubei.googleapis.com`. The key (`?key=`) is omitted when `authHeaders` are non-empty — only the Bearer token is sent (`RetrofitOkHttpHelper`).

**iOS:** Matches Android exactly — `postTV()` omits `?key=` when `authToken != nil`, appending only the Bearer header. When unauthenticated, the WEB key is used.

### 2.2 Player Request Headers
| | Android | iOS |
|-|---------|-----|
| Client Name Header | Not observed | `X-YouTube-Client-Name: 5` (iOS client) |
| Client Version Header | Not observed | `X-YouTube-Client-Version: 20.11.6` |
| User-Agent | iOS YouTube UA | `com.google.ios.youtube/20.11.6 (iPhone10,4; U; CPU iOS 16_7_7 like Mac OS X)` |
| Comment in code | — | Says "ANDROID" but actually sends iOS context |
| **Status** | Client config matches — minor log message confusion |

### 2.3 URL Session Headers
| | Android | iOS |
|-|---------|-----|
| Default headers | Per-request | Global via `URLSessionConfiguration.default` with `X-YouTube-Client-Name: 1`, `X-YouTube-Client-Version: 2.20240101.00.00`, `Origin: https://www.youtube.com` |
| **Issue** | The global headers leak into player requests (which should be iOS/5 client) — potential mismatch |

### 2.4 Browse IDs (Completeness)
| Browse ID | Android | iOS |
|-----------|---------|-----|
| `FEwhat_to_watch` | ✅ Home | ✅ Home |
| `FEtrending` | ✅ Trending | ✅ Trending |
| `FEsubscriptions` | ✅ Subscriptions | ✅ Subscriptions |
| `FEhistory` | ✅ History | ✅ History |
| `FEmy_videos` | ✅ My Videos | ✅ (used for playlists) |
| `FEshorts` | ✅ Shorts | ❌ |
| `FEmusic_home` / music | ✅ Music | ❌ |
| `FEsportsau` / sports | ✅ Sports | ❌ |
| Gaming | ✅ | ❌ |
| News | ✅ | ❌ |
| Live | ✅ | ❌ |
| Kids Home | ✅ | ❌ |

### 2.5 Search Options
| | Android | iOS |
|-|---------|-----|
| Filters | Upload date, duration, type, features, sorting options (bitwise OR) | None — search is unfiltered |
| Voice search | ✅ | ❌ |
| Search history | Managed via service | ❌ |

---

## 3. MODEL DIFFERENCES

### 3.1 Video Model
| Field | Android | iOS | Gap |
|-------|---------|-----|-----|
| id/videoId | `String videoId` | `String id` | Naming only |
| title | `String title` | `String title` | ✅ |
| secondTitle/subtitle | `CharSequence secondTitle` | ❌ | Missing — shows channel/views/date info |
| description | `String description` | `String? description` | ✅ |
| channelId | `String channelId` | `String? channelId` | ✅ |
| author/channelTitle | `String author` | `String channelTitle` | Naming only |
| thumbnailURL | `String cardImageUrl` + `bgImageUrl` | `URL? thumbnailURL` | Single thumb vs multiple |
| duration | `long durationMs` | `TimeInterval? duration` (seconds) | Unit difference |
| viewCount | N/A (in secondTitle) | `Int? viewCount` | ✅ |
| percentWatched | `float percentWatched` | `Double? watchProgress` | Not persisted in iOS |
| startTimeSeconds | `int startTimeSeconds` | ❌ | Missing |
| isLive | `boolean isLive` | `Bool isLive` | ✅ |
| isUpcoming | `boolean isUpcoming` | `Bool isUpcoming` | ✅ |
| isShorts | `boolean isShorts` | `Bool isShort` | ✅ |
| isMovie | `boolean isMovie` | ❌ | Missing |
| isChapter | `boolean isChapter` | ❌ | Missing |
| isSubscribed | `boolean isSubscribed` | ❌ | Missing |
| playlistId | `String playlistId` | `String? playlistId` | ✅ |
| playlistIndex | `int playlistIndex` | `Int? playlistIndex` | ✅ |
| playlistParams | `String playlistParams` | ❌ | Missing |
| reloadPageKey | `String reloadPageKey` | ❌ | Missing |
| previewUrl | `String previewUrl` | ❌ | Missing (animated preview) |
| badge | `String badge` | `[String] badges` | Array vs single |
| hasNewContent | `boolean hasNewContent` | ❌ | Missing |
| clickTrackingParams | `String clickTrackingParams` | ❌ | Missing |
| deArrowTitle | `String deArrowTitle` | ❌ | Missing |
| mediaItem | `MediaItem mediaItem` | ❌ | Missing (no raw API item reference) |
| likeCount/dislikeCount | `String likeCount/dislikeCount` | ❌ | Missing |
| subscriberCount | `String subscriberCount` | ❌ | Missing |
| volume | `float volume` | ❌ | Missing |
| group reference | `WeakReference<VideoGroup>` | ❌ | Missing (used for pagination) |

### 3.2 VideoGroup Model
| Field | Android | iOS | Gap |
|-------|---------|-----|-----|
| id | `int mId` | `UUID id` | Different ID scheme |
| title | `String mTitle` | `String? title` | ✅ |
| videos | `List<Video> mVideos` | `[Video] videos` | ✅ |
| mediaGroup | `MediaGroup mMediaGroup` | ❌ | Missing (raw API group ref for continuation) |
| section | `BrowseSection mSection` | ❌ | Missing |
| position | `int mPosition` | ❌ | Missing (group position in multi-grid) |
| action | `int mAction` (6 types) | `Action action` (4 types) | Missing: REMOVE_AUTHOR, SYNC |
| nextPageToken | ❌ (uses `MediaGroup` continuation) | `String? nextPageToken` | Different pagination approach |

### 3.3 BrowseSection Model
| Field | Android | iOS | Gap |
|-------|---------|-----|-----|
| id | `int mId` (MediaGroup.TYPE_*) | `String id` | Different ID type |
| title | `String mTitle` | `String title` | ✅ |
| type | `int mType` (6 display types) | `SectionType enum` (11 types) | Different granularity |
| iconResId | `int mResId` | ❌ | Missing |
| iconUrl | `String mIconUrl` | ❌ | Missing |
| isAuthOnly | `boolean mIsAuthOnly` | ❌ | Missing |
| enabled | `boolean mEnabled` | ❌ | Missing (togglable in Android sidebar) |
| data | `Object mData` | ❌ | Missing |

---

## 4. PLAYBACK DIFFERENCES

### 4.1 Player Engine
| | Android | iOS |
|-|---------|-----|
| Engine | ExoPlayer (custom fork, DASH+HLS+progressive) | AVPlayer (native, HLS primary) |
| Format selection | Full DASH manifest parsing, adaptive bitrate, codec preference | HLS manifest URL → AVPlayer handles quality |
| Quality switching | Manual quality picker dialog (HQDialogController) | ❌ No quality picker |
| Audio track selection | ✅ | ❌ |
| Subtitle selection | ✅ (SubtitleManager) | ❌ (toggle only in settings) |
| Background playback | PiP + audio-only background mode | Toggle in settings (using AVPlayer PiP) |

### 4.2 Video Loading Sequence
**Android:**
1. `VideoLoaderController.loadVideo()` → MediaItemService.getFormatInfoObserve()
2. Parse DASH manifest → select format tracks (video + audio + subtitles)
3. Apply quality preference from PlayerData
4. Pass to ExoPlayer

**iOS:**
1. `PlaybackViewModel.load(video:)` → InnerTubeAPI.fetchPlayerInfo(videoId:)
2. Extract HLS URL (preferred) or best muxed MP4 (fallback)
3. Create AVPlayerItem(url:)
4. `player.replaceCurrentItem(with:)`

### 4.3 Watch State Persistence
| | Android | iOS |
|-|---------|-----|
| Watch position | Saved via `VideoStateService` per video | `watchProgress` field on Video but NOT persisted |
| Resume playback | ✅ Seeks to saved position | ❌ Always starts from beginning |
| Watched status | ✅ percentWatched tracked | ❌ |

### 4.4 SponsorBlock Integration
| Feature | Android | iOS |
|---------|---------|-----|
| Enabled toggle | ✅ | ✅ |
| Category selection | ✅ (9 categories) | ✅ (8 categories — missing `poi_highlight`) |
| Per-category action | Skip, Skip+Toast, Dialog, Do Nothing | Auto-skip only |
| Progress bar markers | ✅ (color-coded per category) | ✅ (green only) |
| Skip toast/button | ✅ | ✅ |
| Excluded channels | ✅ | ❌ |
| "Don't skip again" | ✅ | ❌ |
| Paid content notification | ✅ | ❌ |
| Minimum segment duration | ✅ | ❌ |

### 4.5 Playback Controls
| Control | Android | iOS |
|---------|---------|-----|
| Play/Pause | ✅ | ✅ |
| Seek (forward/back) | Configurable increments | Fixed 10s back / 30s forward |
| Speed control | In-player dialog | Settings only |
| Quality selection | In-player HQ dialog | ❌ |
| Subtitles | In-player selection | Settings toggle |
| Chapters | ✅ | ❌ |
| Loop/repeat | ✅ | ❌ |
| Related videos | ✅ (SuggestionsController) | ✅ (via search) |
| Like/Dislike | ✅ | ❌ |
| Share | ✅ | ❌ |
| Add to playlist | ✅ | ❌ |

---

## 5. UI/NAVIGATION DIFFERENCES

### 5.1 App Structure
| | Android | iOS |
|-|---------|-----|
| Root layout | Leanback BrowseSupportFragment (sidebar + content) | TabView (iOS) / NavigationSplitView (macOS) |
| Section nav | Left sidebar with icons | Segmented picker in toolbar |
| Section count | 18+ sections (configurable, reorderable) | 6 fixed sections |
| Section toggle | ✅ Enable/disable sections in sidebar settings | ❌ All sections always shown |
| Pinned sections | ✅ Pin channels/playlists to sidebar | ❌ |

### 5.2 Home Feed Layout
| | Android | iOS |
|-|---------|-----|
| Layout | Multiple horizontal rows (TYPE_ROW) — each row is a group | Single vertical grid |
| Row titles | ✅ "Recommended", "Trending", etc. | ❌ (all videos in one flat grid) |
| **Impact** | Android shows richer sectioned home; iOS flattens all into one list |

### 5.3 Video Card Context Menu
| | Android | iOS |
|-|---------|-----|
| Long press | Full context menu (Play, Add to Queue, Playlist, Share, Channel, Block, etc.) | ❌ No context menu |

### 5.4 Multi-Account
| | Android | iOS |
|-|---------|-----|
| Multi-account | ✅ (AccountSelectionPresenter, switch accounts) | ❌ Single account |

---

## 6. SETTINGS DIFFERENCES

### Missing Settings (Android has, iOS doesn't)

#### General
- Exit shortcut behavior (double/single back)
- Background playback shortcut (home, home+back, back)
- History state (auto/enabled/disabled)
- Screensaver timeout + dimming
- VPN toggle
- Child mode
- Password protection
- Proxy settings
- Changelog display

#### Player
- OK button behavior (UI, pause, toggle speed)
- Controls auto-hide timeout
- Seek confirmation pause
- Clock on player
- Remaining time display
- Video buffer type
- Resize mode + zoom + aspect ratio + rotation + flip
- Seek preview mode (none, single, carousel)
- Audio delay
- Audio/subtitle language preference
- All speed mode
- Playback mode (loop, shuffle)
- Sleep timer
- Quality info display
- Speed per video
- Time correction

#### Search
- Voice search
- Instant voice search
- Search history toggle

#### SponsorBlock
- Per-category action (skip/toast/dialog/nothing)
- Excluded channels
- Don't skip segment again
- Paid content notification
- Minimum segment duration

#### UI
- Channel category sorting (default, name, new content, last viewed)
- Playlists style (grid vs rows)
- Uploads old look
- UI scale
- Subtitle style customization

---

## 7. MISSING FEATURES (present in Android, absent in iOS)

| Feature | Android Component | Difficulty |
|---------|-------------------|------------|
| Shorts feed | BrowsePresenter + SHORTS_GRID | Medium |
| Music/Gaming/News/Live/Sports/Kids feeds | BrowsePresenter row mappings | Easy (browse IDs) |
| Notifications | NotificationsService | Medium |
| Live chat | ChatController | Hard |
| Comments | CommentsController | Hard |
| Video chapters | BasePresenter chapter support | Medium |
| Remote control / Cast | RemoteController | Hard |
| Auto frame rate | AutoFrameRateController | Medium |
| Quality selection dialog | HQDialogController | Medium |
| Watch position tracking | VideoStateService + VideoStateController | Medium |
| Like/Dislike buttons | MediaItemService interaction | Easy |
| Subscribe/Unsubscribe | MediaItemService interaction | Easy |
| Add to playlist | MediaItemService interaction | Medium |
| Share video | System share sheet | Easy |
| Play from queue | Playlist.java local queue | Medium |
| Blocked channels | BlockedChannelData | Easy |
| Channel groups | ChannelGroupService | Medium |
| Search filters | SearchPresenter options | Easy |
| Search history | SearchData + service | Easy |
| Video context menu | VideoMenuPresenter | Medium |
| Multi-account | AccountSelectionPresenter | Medium |
| Pinned sections | SidebarService | Medium |
| DeArrow title replacement | deArrowTitle integration | Easy |
| Password protection | AccountsData | Easy |
