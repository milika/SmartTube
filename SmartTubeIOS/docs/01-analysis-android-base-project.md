# Android SmartTube Base Project — Analysis

## Architecture Overview

The Android SmartTube app uses a **layered service architecture** with clean separation:

```
┌──────────────────────────────┐
│   smarttubetv (TV UI layer)  │  Leanback UI, Fragments
├──────────────────────────────┤
│   common (Shared logic)      │  Presenters, Models, Prefs, Utils
├──────────────────────────────┤
│   MediaServiceCore (git sub) │  YouTube API implementation
│   ├── youtubeapi             │  InnerTube endpoints, JSON parsing
│   ├── mediaserviceinterfaces │  Service contracts (interfaces)
│   └── sharedutils            │  Logging, RxJava helpers, prefs
├──────────────────────────────┤
│   ExoPlayer (custom fork)    │  Video playback engine
└──────────────────────────────┘
```

> **Note:** `MediaServiceCore/` and `SharedModules/` are **git submodules** not initialised in this workspace. All analysis is based on the `common/` module which imports from them.

---

## Key Design Patterns

### 1. Singleton Presenters

Every presenter follows the same singleton pattern:

```java
public class BrowsePresenter extends BasePresenter<BrowseView> {
    private static BrowsePresenter sInstance;

    private BrowsePresenter(Context context) { super(context); }

    public static BrowsePresenter instance(Context context) {
        if (sInstance == null) sInstance = new BrowsePresenter(context);
        sInstance.setContext(context);
        return sInstance;
    }
}
```

**Presenters found (52+):**
| Presenter | Purpose |
|-----------|---------|
| `BrowsePresenter` | Home/Trending/Subscriptions/History/Channels/Playlists/Settings sections |
| `SearchPresenter` | Search with filters, voice, suggestions |
| `PlaybackPresenter` | Video playback orchestrator — delegates to 10 controllers |
| `ChannelPresenter` | Channel page |
| `ChannelUploadsPresenter` | Channel uploads grid |
| `DetailsPresenter` | Video details |
| `SignInPresenter` | Sign-in orchestrator (delegates to YTSignIn or GoogleSignIn) |
| `YTSignInPresenter` | YouTube device-code sign-in |
| `GoogleSignInPresenter` | Google OAuth sign-in |
| `AccountSelectionPresenter` | Multi-account selection dialog |
| `SplashPresenter` | App launch |
| `AppDialogPresenter` | Dialog management |

### 2. Service Layer (Interfaces → Implementation)

The `common/` module depends on **interfaces only**:

```java
// In BasePresenter:
protected ContentService getContentService() {
    return YouTubeServiceManager.instance().getContentService();
}
protected MediaItemService getMediaItemService() {
    return YouTubeServiceManager.instance().getMediaItemService();
}
protected SignInService getSignInService() {
    return YouTubeServiceManager.instance().getSignInService();
}
```

**Service interfaces:**
| Interface | Purpose | Key Methods |
|-----------|---------|-------------|
| `ContentService` | Browse feeds | `getHomeObserve()`, `getTrendingObserve()`, `getSubscriptionsObserve()`, `getHistoryObserve()`, `getSearchObserve()`, `getShortsObserve()`, `getMusicObserve()`, `getGamingObserve()`, `getNewsObserve()`, `getLiveObserve()`, `getKidsHomeObserve()`, `getSportsObserve()` |
| `MediaItemService` | Video metadata & formats | `getMetadataObserve()`, `getFormatInfoObserve()` |
| `SignInService` | Auth | `signInObserve()`, `getAccounts()`, `selectAccount()`, `isSigned()` |
| `CommentsService` | Comments | Referenced in `ChatController`, `CommentsController` |
| `NotificationsService` | Notifications | `getNotificationItemsObserve()` |
| `ChannelGroupService` | Channel groups | Referenced in `ChannelGroupServiceWrapper` |

### 3. ReactiveX (RxJava) Everywhere

All service methods return `Observable<...>`. Presenters subscribe and dispose:

```java
mLoadAction = contentService.getSearchObserve(searchText, options)
    .subscribe(
        mediaGroups -> { ... },
        error -> { ... },
        () -> { ... }
    );
```

### 4. MediaServiceManager (Facade)

Wraps all services into one convenient facade with callbacks:

```java
public class MediaServiceManager implements OnAccountChange {
    private final MediaItemService mItemService;
    private final ContentService mContentService;
    private final SignInService mSignInService;
    
    public void loadMetadata(Video video, OnMetadata callback) { ... }
    public void loadChannelUploads(Video item, OnMediaGroup callback) { ... }
    public void loadSubscribedChannels(OnMediaGroup callback) { ... }
}
```

### 5. Playback Controller Chain

`PlaybackPresenter` delegates to 10 controllers, each handling one concern:

```java
mEventListeners.add(new VideoStateController());     // Resume position, watched state
mEventListeners.add(new SuggestionsController());    // Related videos
mEventListeners.add(new VideoLoaderController());    // Format loading & selection
mEventListeners.add(new PlayerUIController());       // UI overlays
mEventListeners.add(new RemoteController(ctx));      // Cast/remote control
mEventListeners.add(new SponsorBlockController());   // SponsorBlock integration
mEventListeners.add(new AutoFrameRateController());  // Frame rate matching
mEventListeners.add(new HQDialogController());       // Quality selection dialog
mEventListeners.add(new ChatController());           // Live chat
mEventListeners.add(new CommentsController());       // Comments
```

---

## Model Classes

### Video (Android)
```java
public final class Video {
    public int id;
    public String title;
    public String deArrowTitle;
    public CharSequence secondTitle;        // subtitle/description line
    public String description;
    public String category;
    public int itemType;
    public String channelId, videoId;
    public String playlistId, remotePlaylistId;
    public int playlistIndex;
    public String playlistParams;
    public String reloadPageKey;
    public String bgImageUrl, cardImageUrl, altCardImageUrl;
    public String author;
    public String badge;
    public String previewUrl;               // video preview animation URL
    public float percentWatched;
    public int startTimeSeconds;
    public MediaItem mediaItem;             // original API response item
    public MediaItem nextMediaItem;
    public MediaItem shuffleMediaItem;
    public PlaylistInfo playlistInfo;
    public boolean hasNewContent;
    public boolean isLive, isUpcoming, isUnplayable, isShorts, isChapter, isMovie;
    public boolean isSubscribed;
    public int groupPosition;
    public String clickTrackingParams;
    public String likeCount, dislikeCount, subscriberCount;
    public float volume;
    public boolean deArrowProcessed;
    // ...plus 20+ more fields
}
```

### VideoGroup (Android)
```java
public class VideoGroup {
    public static final int ACTION_APPEND = 0;
    public static final int ACTION_REPLACE = 1;
    public static final int ACTION_REMOVE = 2;
    public static final int ACTION_REMOVE_AUTHOR = 3;
    public static final int ACTION_SYNC = 4;
    public static final int ACTION_PREPEND = 5;
    
    private int mId;
    private String mTitle;
    private List<Video> mVideos;
    private MediaGroup mMediaGroup;    // keeps reference to raw API group
    private BrowseSection mSection;
    private int mPosition;
    private int mAction;
}
```

### BrowseSection (Android)
Section types: `TYPE_GRID`, `TYPE_ROW`, `TYPE_SETTINGS_GRID`, `TYPE_MULTI_GRID`, `TYPE_ERROR`, `TYPE_SHORTS_GRID`

Section IDs mapped to `MediaGroup.TYPE_*`: HOME, SHORTS, TRENDING, KIDS_HOME, SPORTS, LIVE, MY_VIDEOS, GAMING, NEWS, MUSIC, CHANNEL_UPLOADS, SUBSCRIPTIONS, HISTORY, BLOCKED_CHANNELS, USER_PLAYLISTS, NOTIFICATIONS, PLAYBACK_QUEUE, SETTINGS.

---

## Browse Sections (Android has 18+, iOS has 6)

| Section | Android | iOS |
|---------|---------|-----|
| Home | ✅ (TYPE_ROW — multiple row groups) | ✅ (single grid) |
| Trending | ✅ (TYPE_ROW) | ✅ (grid) |
| Subscriptions | ✅ (TYPE_GRID, auth) | ✅ (grid, auth) |
| History | ✅ (TYPE_GRID, auth) | ✅ (grid, auth) |
| Playlists | ✅ (TYPE_ROW or TYPE_GRID) | ✅ (list) |
| Channels | ✅ (TYPE_MULTI_GRID, multiple sorting modes) | ✅ (list) |
| Shorts | ✅ (TYPE_SHORTS_GRID) | ❌ |
| Music | ✅ (TYPE_ROW) | ❌ |
| Gaming | ✅ (TYPE_ROW) | ❌ |
| News | ✅ (TYPE_ROW) | ❌ |
| Live | ✅ (TYPE_ROW) | ❌ |
| Sports | ✅ (TYPE_ROW) | ❌ |
| Kids Home | ✅ (TYPE_ROW) | ❌ |
| My Videos | ✅ (TYPE_GRID) | ❌ |
| Notifications | ✅ (TYPE_GRID) | ❌ |
| Playback Queue | ✅ (TYPE_GRID, local) | ❌ |
| Blocked Channels | ✅ (TYPE_GRID, local) | ❌ |
| Settings | ✅ (TYPE_SETTINGS_GRID) | ✅ (separate tab) |

---

## Preferences (Android has 15+ preference classes)

| Android Pref Class | Purpose | iOS Equivalent |
|--------------------|---------|----------------|
| `GeneralData` | UI behavior, exit shortcuts, history, screensaver | Partial in `AppSettings` |
| `PlayerData` | Quality, speed, background mode, buffer, subtitles, A/V format, resize, zoom, AFR, seek preview | Partial in `AppSettings` |
| `PlayerTweaksData` | Low-level player tweaks | ❌ |
| `MainUIData` | Channel sorting, playlists style, uploads look, scale | Partial in `AppSettings` |
| `SearchData` | Voice, instant search, history | ❌ |
| `SponsorBlockData` | SB enabled, categories, actions per category, excluded channels, color mapping | Partial in `AppSettings` |
| `DeArrowData` | DeArrow enabled | ✅ in `AppSettings` |
| `AccountsData` | Password protection, multi-account | ❌ |
| `BlockedChannelData` | Channel blocking | ❌ |
| `RemoteControlData` | Cast/remote settings | ❌ |
| `AppPrefs` | Central preference store, profiles | ❌ |

---

## API Configuration (Android)

### Client Contexts
| Client | Name | Version | Use Case | Base URL |
|--------|------|---------|----------|----------|
| WEB | `"WEB"` | `2.20260206.01.00` | Browse, search, home | `www.youtube.com/youtubei/v1` |
| iOS | `"iOS"` | `20.11.6` | Stream URLs (HLS/DASH) | `youtubei.googleapis.com/youtubei/v1` |
| TVHTML5 | `"TVHTML5"` | `7.20230405.08.01` | Auth'd account calls | `youtubei.googleapis.com/youtubei/v1` |

### API Keys
| Key | Value | Use |
|-----|-------|-----|
| WEB | `AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8` | Browse/Search on www.youtube.com |
| TV | `AIzaSyDCU8hByM-4DrUqRUYnGn-3llEO78bcxq8` | Authenticated InnerTube requests |

### OAuth Credentials (Device Code Flow)
- Client ID: `861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com`
- Client Secret: `SboVhoG9s0rNafixCSGGKXAT`
- Scope: `http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content`
- Sign-in URL: `https://yt.be/activate` (Android uses `yt.be/activate`, NOT `youtube.com/activate`)

### Key Endpoints
| Endpoint | Method | Client | Auth | Purpose |
|----------|--------|--------|------|---------|
| `/browse` | POST | WEB | Optional | Home, trending, subscriptions, history, channels, playlists |
| `/search` | POST | WEB | Optional | Search results |
| `/player` | POST | iOS | No | Stream URLs (HLS, DASH, formats) |
| `/account/accounts` | POST | TVHTML5 + TV key | Bearer | Account name/avatar |
| `/device/code` | POST | - | - | OAuth device code request |
| `/token` | POST | - | - | OAuth token exchange/refresh |
| `suggestqueries-clients6.youtube.com/complete/search` | GET | - | No | Search suggestions |
| `sponsor.ajay.app/api/skipSegments` | GET | - | No | SponsorBlock segments |
| `sponsor.ajay.app/api/branding` | GET | - | No | DeArrow branding |

---

## Playback Controllers (Android)

| Controller | Responsibility | iOS Equivalent |
|-----------|---------------|----------------|
| `VideoStateController` | Save/restore watch position, mark watched | ❌ (no watch position tracking) |
| `SuggestionsController` | Load related videos, suggestions rows | Partial (related via search) |
| `VideoLoaderController` | Format selection, DASH/HLS preference, quality auto-selection | Partial (HLS fallback only) |
| `PlayerUIController` | Controls overlay, OSD, buttons, gestures | Partial (basic overlay) |
| `RemoteController` | Cast, remote control protocol | ❌ |
| `SponsorBlockController` | Segment skip, toast, dialog, color markers | ✅ (basic auto-skip + markers) |
| `AutoFrameRateController` | Frame rate switching to match content | ❌ |
| `HQDialogController` | Quality selection dialog | ❌ |
| `ChatController` | Live chat overlay | ❌ |
| `CommentsController` | Comments section | ❌ |
