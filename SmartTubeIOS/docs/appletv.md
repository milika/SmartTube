# SmartTube — Apple TV (tvOS) Support Plan

> Research and plan-of-attack for porting SmartTubeIOS to tvOS. No code changes — planning document only.
> Current date: April 2026.

---

## Overview

Apple TV (tvOS) is the **natural home** for a YouTube client focused on ad-free, SponsorBlock-assisted playback. The existing SmartTubeIOS codebase is deliberately split into a Foundation-only `SmartTubeIOSCore` layer and a SwiftUI `SmartTubeIOS` UI layer — this two-target architecture makes tvOS adoption significantly cheaper than a greenfield port.

The biggest challenge is **input model**: tvOS has no touchscreen. All navigation is Siri Remote (directional pad + select button + swipe surface) or a game controller. Every UIKit-level gesture (`UIViewRepresentable`, `UIPanGestureRecognizer`) must be replaced or conditioned out.

---

## Platform constraints & tvOS vs iOS delta

| Area | iOS / macOS today | tvOS requirement |
|------|-------------------|-----------------|
| **Minimum OS** | iOS 17, macOS 14 | tvOS 17 (same SwiftUI feature set) |
| **UIKit** | `#if canImport(UIKit)` guards already in place | UIKit is available on tvOS but `UIPanGestureRecognizer` / `UIViewRepresentable` swipe overlays must be replaced with focus-engine navigation |
| **AVKit** | `AVPlayerLayerView` (`UIViewRepresentable` + `AVPlayerLayer`) | Same on tvOS. `AVPlayerViewController` is preferred on tvOS for system transport controls but `AVPlayerLayer` also works |
| **ActivityKit / Live Activities** | `#if canImport(ActivityKit)` — already guarded | Not available on tvOS. Guards already handle this |
| **PHPhotoLibrary** | Used in `VideoDownloadService` | Not available on tvOS. Download feature must be hidden/disabled |
| **NSPasteboard / UIPasteboard** | Used in QR code + sign-in copy flows | `UIPasteboard` not available on tvOS; the TV sign-in flow is already the primary path (`yt.be/activate`), so no functional gap |
| **PiP (Picture-in-Picture)** | `AVPictureInPictureController` wrapped in `#if os(iOS)` | Not supported on tvOS. Already conditionally compiled |
| **ShareExtension** | iOS-only app extension | Not applicable to tvOS |
| **Navigation model** | `TabView` (iOS) / `NavigationSplitView` (macOS) | tvOS: `TabView` works but focus-ring must be considered; `NavigationSplitView` is common for tvOS too |
| **Keyboard input** | SwiftUI `TextField` with on-screen keyboard | tvOS: system keyboard overlay via `TextField`; works identically in SwiftUI |
| **Focus engine** | Not used | Required: `@FocusState`, `.focusable()`, `.buttonStyle(.card)` for tvOS highlight behavior |
| **Siri Remote swipes** | N/A | Replace `SwipeGestureOverlay` (`UIPanGestureRecognizer`) with SwiftUI `DragGesture` or `onMoveCommand` |
| **Fonts / layout** | Compact mobile typography | tvOS: larger type, 10-foot viewing distance. SF Pro Display at ≥ 30 pt for body text |
| **Safe area** | iOS notch / dynamic island | tvOS overscan safe area — `ignoresSafeArea()` must be audited |
| **WidgetKit / DownloadWidget** | iOS-only | Not applicable to tvOS |

---

## What ports for free (zero or near-zero changes)

### `SmartTubeIOSCore` — 100% portable as-is

All 14 files in `Sources/SmartTubeIOSCore/` are Foundation-only with no UIKit, no SwiftUI, no ActivityKit, and no platform-exclusive APIs. Adding `.tvOS(.v17)` to the `Package.swift` platforms list is the **only change** required to compile this target on tvOS.

| File | Portable? | Notes |
|------|-----------|-------|
| `InnerTubeAPI.swift` | ✅ Zero changes | Pure `URLSession` / `async`; actors |
| `InnerTubeClients.swift` | ✅ Zero changes | Constants only |
| `YouTubeClientCredentials.swift` | ✅ Zero changes | Actor; Foundation networking |
| `YouTubeLinkHandler.swift` | ✅ Zero changes | URL parsing |
| `SponsorBlockService.swift` | ✅ Zero changes | Actor; Foundation networking |
| `Video.swift` | ✅ Zero changes | Pure model |
| `VideoGroup.swift` | ✅ Zero changes | Pure model |
| `VideoStateStore.swift` | ✅ Zero changes | UserDefaults; serial DispatchQueue (tvOS OK) |
| `AppSettings.swift` | ✅ Zero changes | Codable struct; UserDefaults |
| `AppSubsystem.swift` | ✅ Zero changes | Logger subsystem string |
| `DownloadActivityAttributes.swift` | ✅ Zero changes | Already guarded with `#if canImport(ActivityKit)` |
| `SearchFilter.swift` | ✅ Zero changes | Model + protobuf encoding |
| `ShortsNavigation.swift` | ✅ Zero changes | Navigation index logic |
| `TimeFormatting.swift` | ✅ Zero changes | Pure formatting |

### Services

| File | Portable? | Notes |
|------|-----------|-------|
| `AuthService.swift` | ✅ Near-zero | The TV OAuth + device-code flow is already primary. `UIPasteboard` usage is guarded and can be `#if`-fenced for tvOS (copy is irrelevant — user types code on phone) |
| `SettingsStore.swift` | ✅ Zero changes | `@Observable`; pure UserDefaults |
| `VideoDownloadService.swift` | ✅ Not included | Downloads are an iOS-only feature; not part of the Apple TV product |

### ViewModels

| File | Portable? | Notes |
|------|-----------|-------|
| `BrowseViewModel.swift` | ✅ Zero changes | Pure async data fetching |
| `HomeViewModel.swift` | ✅ Zero changes | Pure async data fetching |
| `SearchViewModel.swift` | ✅ Zero changes | `.task(id:)` debounce; no UIKit |
| `PlaylistViewModel.swift` | ✅ Zero changes | Pure async |
| `PlaybackViewModel.swift` | ⚠️ Minor platform guards | `#if canImport(UIKit)` guards for background audio session (`AVAudioSession`) are already in place. `AVAudioSession` IS available on tvOS — verify existing guards don't accidentally exclude tvOS |

### Views (SwiftUI — near-zero or low-effort)

| File | Portable? | Notes |
|------|-----------|-------|
| `HomeView.swift` | ✅ Low effort | Horizontal rows, `LazyHStack` — maps well to 10-foot grid. Cardify thumbnails with `.buttonStyle(.card)` |
| `BrowseView.swift` | ✅ Low effort | Tab/shelf layout already in use |
| `VideoCardView.swift` | ✅ Low effort | Needs `.focusable()` + card shadow on tvOS |
| `SearchView.swift` | ✅ Low effort | SwiftUI `TextField` works on tvOS |
| `SettingsView.swift` | ✅ Low effort | `List`-based; focus-engine works naturally |
| `LibraryView.swift` | ✅ Low effort | Similar to browse; scroll + focus |
| `PlaylistView.swift` | ✅ Low effort | List-based; inherits focus |
| `ChannelView.swift` | ✅ Low effort | Grid / list view; same |
| `ChannelListView.swift` | ✅ Low effort | List; same |
| `SignInView.swift` | ✅ Zero changes | The device-code + QR flow is _designed_ for TV. User reads a code on screen and activates on phone — no keyboard input required. This is already the primary sign-in path |
| `ScrollOffsetPreserver.swift` | ⚠️ Minor | May contain UIKit scroll view hooks; verify on tvOS |

---

## What requires real work

### 1. Player: `SwipeGestureOverlay` (`UIViewRepresentable` + `UIPanGestureRecognizer`)

**The biggest blocker.** Both `PlayerView` and `ShortsPlayerView` use a UIKit-level `UIPanGestureRecognizer` installed via `UIViewRepresentable` to capture swipe gestures above `AVPlayerLayer`. This pattern is tvOS-incompatible (no touch screen).

**TV replacement strategy:**
- Replace `SwipeGestureOverlay` with a conditional compile block: keep it for iOS, provide a tvOS path using Siri Remote swipe events via `.onMoveCommand` (directional D-pad) or by wrapping `AVPlayerViewController` (recommended on tvOS — it provides system transport controls for free via the Siri Remote)
- Swipe-left/right for next/previous video maps to Menu or swipe on the Siri Remote touch surface (detected via `DragGesture` in SwiftUI on tvOS)

**Work estimate:** Medium — requires new `#if os(tvOS)` branch in both player views.

### 2. `AVPlayerLayerView` (bare `UIViewRepresentable` + `AVPlayerLayer`)

The current approach bypasses `AVPlayerViewController` specifically to avoid UIKit accessibility tree interference with XCUITest. On tvOS this tradeoff reverses: `AVPlayerViewController` delivers system Siri Remote transport controls (play/pause, scrubbing, 10-second skip) for free.

**TV recommendation:** Use `AVPlayerViewController` on tvOS wrapped in `UIViewRepresentable` (it is standard practice). Keep the bare `AVPlayerLayer` path for iOS.

### 3. Shorts

Shorts are vertical-swipe driven. On Apple TV, Shorts are less common and the swipe model doesn't translate naturally to a Siri Remote. Two options:
- **Option A:** Surface Shorts in a regular grid/list (no swipe player) — minimal work, browsable.
- **Option B:** Implement Shorts as a focus-driven vertical scroll where pressing up/down on the D-pad advances to next/previous short — medium work.

Recommended starting point: Option A (grid), Option B as a follow-up.

### 4. Picture-in-Picture

Already `#if os(iOS)` — simply not available on tvOS. No work needed, it's already excluded.

### 5. Download feature

Not included in the Apple TV product. The `DownloadWidget` target is an iOS-only app extension and is not added to the tvOS target. The download button in the player is simply not present in the tvOS UI layer.

### 6. Navigation shell (`RootView`)

`RootView` already handles `os(macOS)` vs iOS branches. A third `os(tvOS)` branch is needed:
- tvOS navigation typically uses a top-bar `TabView` (tab items shown at the top of the screen) or a `NavigationSplitView`
- The existing `MainTabView` (iOS) renders tab items at the bottom — this works on tvOS but the top-tab pattern is the Apple-recommended TV style

### 7. Focus engine throughout the UI

Every tappable element — `VideoCardView`, buttons in `PlayerView`, category chips in `BrowseView`, etc. — needs `.focusable()` and an appropriate `buttonStyle` or `hoverEffect` for tvOS. This is cosmetic but significant for usability.

### 8. Typography & layout scaling

10-foot UI requires larger type. Options:
- Add a `tvOS`-specific `Font` extension that scales up sizes
- Use Dynamic Type with appropriate base sizes per platform
- Audit all hardcoded `.font(.caption)`, `.font(.subheadline)` etc. and add `#if os(tvOS)` overrides

---

## New tvOS-specific capabilities (potential future features)

| Feature | Notes |
|---------|-------|
| **Top Shelf Extension** | Show featured/recommended videos in the Apple TV home screen shelf. Separate app extension target, medium effort |
| **Siri integration** | `INPlayMediaIntent` — "Hey Siri, play X on SmartTube" — requires `Intents` framework + media metadata |
| **Universal Remote control** | CEC passthrough means the TV remote works if `AVPlayerViewController` is used — free with approach above |
| **Apple TV Remote app** | Works automatically when `AVPlayerViewController` is used |
| **Focus-driven search** | The SwiftUI `TextField` keyboard overlay on tvOS is functional; a grid search results page already exists |

---

## Package.swift changes required

```
// Current:
platforms: [
    .iOS(.v17),
    .macOS(.v14),
]

// Required:
platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .tvOS(.v17),
]
```

Both targets (`SmartTubeIOSCore`, `SmartTubeIOS`) need the platform added. `SmartTubeIOSCore` compiles with zero source changes after this. `SmartTubeIOS` requires the conditional compilation work described above before it compiles clean.

---

## Xcode project changes required

1. Add a new **tvOS app target** in `SmartTubeApp.xcodeproj` (or a new `SmartTubeTVApp` target in a separate scheme)
2. Add a tvOS-specific `AppEntry` / `@main` entry point (`UIApplicationDelegate` on tvOS = `TVApplicationController`-based or SwiftUI `App` — SwiftUI `@main` works identically)
3. Do **not** add tvOS to the existing unified `SmartTube` iOS/macOS target — Apple TV should be its own target to allow platform-specific `Info.plist`, entitlements, and app extension exclusion
4. `project.yml` (XcodeGen) is the source of truth — add a `SmartTubeTV` product entry there

---

## Phase plan

### Phase TV-0 — Core compiles on tvOS (low risk, no user-visible change)

- [ ] Add `.tvOS(.v17)` to `Package.swift` `platforms` array (both targets)
- [ ] Verify `SmartTubeIOSCore` compiles cleanly on tvOS simulator
- [ ] Identify any remaining compiler errors in `SmartTubeIOS` on tvOS
- [ ] Create `SmartTubeTV` Xcode target (via `project.yml`) with bare `@main` entry

### Phase TV-1 — Browsable UI on Apple TV (content visible, no playback)

- [ ] `RootView`: add `#if os(tvOS)` branch with `MainTVSidebarView` (top `TabView` or `NavigationSplitView`)
- [ ] `VideoCardView`: add `.focusable()`, `.buttonStyle(.card)`, and `hoverEffect` for tvOS
- [ ] `BrowseView` / `HomeView`: verify focus traversal, increase card sizes for 10-foot
- [ ] Typography pass: `#if os(tvOS)` font size overrides

### Phase TV-2 — Playback on Apple TV

- [ ] `PlayerView`: add `#if os(tvOS)` branch using `AVPlayerViewController` wrapped in `UIViewRepresentable`
- [ ] Remove / conditionalize `SwipeGestureOverlay` for tvOS; replace with `.onMoveCommand` / Siri Remote D-pad next/prev
- [ ] PiP: already excluded — verify no compile errors on tvOS
- [ ] Verify `PlaybackViewModel` `AVAudioSession` guards work on tvOS

### Phase TV-3 — Full feature parity

- [ ] SponsorBlock skip — works via `PlaybackViewModel` timer; no UI change needed
- [ ] Like / Dislike buttons — add focus-compatible style on tvOS
- [ ] Quality picker — present as full-screen `List` overlay instead of bottom sheet on tvOS
- [ ] Speed picker — same
- [ ] Chapters — chapter markers on progress bar; verify layout at TV sizes
- [ ] Search — verify on-screen keyboard overlay works for search
- [ ] Shorts — implement as grid (Option A) or D-pad swipe player (Option B)

### Phase TV-4 — Polish & extensions (future)

- [ ] Top Shelf Extension for featured content
- [ ] `INPlayMediaIntent` Siri integration
- [ ] tvOS-specific onboarding (sign-in is already designed for TV)
- [ ] UI test suite for tvOS simulator

---

## Risk assessment

| Risk | Severity | Mitigation |
|------|----------|-----------|
| `SwipeGestureOverlay` UIKit swipe pattern has no direct tvOS equivalent | High | Replace with `AVPlayerViewController` system controls + D-pad next/prev; swipe gestures are not idiomatic on TV anyway |
| `AVPlayerLayerView` bare layer loses system transport controls on tvOS | Medium | Use `AVPlayerViewController` on tvOS path; bare layer only needed to fix XCUITest — tvOS UI tests work differently |
| Shorts player entirely touch-driven | Medium | Start with grid display; full swipe player is a v2 feature |
| Focus engine audit is broad (every interactive element) | Medium | Can be done incrementally; broken focus just means keyboard navigation is bad, not that the app crashes |
| Download feature not on tvOS | Low | Simply not included in the tvOS UI target; no platform guards needed |
| `ActivityKit` unavailable on tvOS | Low | Already `#if canImport(ActivityKit)` guarded throughout |
| Performance on Apple TV hardware | Low | Apple TV 4K (A15/A16) is more powerful than iPhone 13; no concerns |

---

## Summary

> **TL;DR:** `SmartTubeIOSCore` is a free port. The auth flow is already TV-native (device code + QR). The main work is (1) the player gesture layer, (2) focus engine throughout the UI, and (3) the navigation shell. Estimated effort: ~3–4 focused phases, with a working browsable Apple TV build achievable after Phase TV-1.

---

## Developer notes — Simulator input mapping

When testing the tvOS app in Xcode Simulator, use the keyboard as a stand-in for the Siri Remote. All conversations about navigation in this doc use this terminology.

| Keyboard key | Siri Remote equivalent | Effect in app |
|---|---|---|
| ↑ ↓ ← → (arrow keys) | D-pad directional swipe | Move focus between elements |
| Enter / Return | Click (select button) | Activate focused element / play video |
| Esc | Menu button (back) | Go back / dismiss |
| Space | Play/Pause button | Toggle playback |

**Focus chain (Home tab):**
```
Tab bar (↓ or enter) → Chips (↓ or enter) → Video list (esc returns to chips)
within chips: (left right) moves focus between chips, (↓) moves to video list, esc returns to tab bar
within video list: esc returns to chips, arrow navigate, up on top row returns to chips
```

You can also open **Hardware → Apple TV Remote** in Simulator for an on-screen remote widget.

** CRITICAL: Make sure our changes do not break iPhone implementation, revise them all in the simulator and on device. **

---

## Apple HIG — Key principles for SmartTube tvOS (April 2026)

This section distils the most relevant rules from the Apple Human Interface Guidelines for tvOS:
[Designing for tvOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-tvos) · [Remotes](https://developer.apple.com/design/human-interface-guidelines/remotes) · [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection)

### Apple TV 4K — official playback controls (tvOS 26)

Source: [Control video playback on Apple TV 4K](https://support.apple.com/en-kg/guide/tv/atvb7944597f/tvos)

#### Play, pause, rewind, fast-forward

| Action | Remote gesture |
|---|---|
| **Play or pause** | Press ⏯ button, or press the center of the clickpad / touch surface |
| **Skip backward / forward 10 seconds** | Press left or right on the clickpad ring or touch surface. Press again for another 10 s. |
| **Continuously rewind / fast-forward** | Press and hold left or right. Press repeatedly to cycle through 2×, 3×, 4× speed. |
| **Resume from rewind/FF** | Press ⏯ |

> Tip: Skipping back 10 s automatically turns on subtitles so you can re-watch that section with captions.

When paused, onscreen controls appear showing elapsed/remaining time and options.

#### Show/hide onscreen playback controls

| Action | Remote gesture |
|---|---|
| **Show controls** | Rest finger on clickpad / touch surface, or press up on clickpad ring (silver remote) |
| **Hide controls** | Press Menu (Back) or ⏯ |

#### Scrubbing (seek to a specific point)

1. Press ⏯ to **pause**.
2. **Swipe left or right** on the clickpad or touch surface to scrub. A preview thumbnail appears above the timeline.
   - *More precise:* circle your finger around the clickpad ring (silver remote only).
3. **Confirm** seek position: press ⏯ to start playback at the new position.
4. **Cancel** (return to original): press Menu or ⏯.

> This is the **official Apple scrub model**: pause first, then swipe. Our current ±10 s D-pad seek is a simplified alternative — the full swipe scrub requires the touch surface, not the D-pad.

#### Subtitles / closed captioning

| Action | Remote gesture |
|---|---|
| Turn on subtitles/CC | Show controls → swipe up → select subtitle icon → choose option |
| Temporarily enable for last 10–30 s | Press left on clickpad ring (up to 3× for 30 s) |
| Turn on subtitles while muted | Press mute button (silver remote only) |

#### Audio options during playback

Show controls → select audio icon → pop-up menu offers: Enhance Dialogue, Reduce Loud Sounds, Audio Track (language / audio descriptions). Close menu with Menu or ⏯.

### Remote — canonical button mapping (HIG requirement)

| Remote gesture | Standard app behaviour | SmartTube current status |
|---|---|---|
| Touch surface swipe | Navigate / change focus | ✅ Focus chain works |
| Touch surface press (select) | Activate control / navigate deeper | ✅ Button select works |
| Back (Menu) button | Return to parent screen; top-level → Home Screen | ✅ `.onExitCommand` dismisses player |
| Play/Pause button | Play / pause / resume media | ✅ `.onPlayPauseCommand` hooked |
| D-pad left/right | Move focus (browse) or seek (player) | ✅ ±10 s seek in player, focus in browse |
| Swipe left/right (touch surface, during pause) | Scrub timeline | ❌ Not yet implemented — swipe requires `DragGesture` on touch surface |

> "In almost all cases, open the parent of the current screen when people press the Back button." — HIG Remotes
>
> "Respond correctly to the Play/Pause button during media playback." — HIG Remotes
>
> "People press before swiping to activate scrubbing mode." — HIG Remotes

### Remote — pitfalls to avoid

- **Do NOT redefine standard gestures.** Left/right in a video list must move focus, not seek. Seeking belongs inside the player context.
- **Avoid responding to inadvertent taps during live video playback.** A resting thumb may generate tap events — `.onTapGesture` in the player risks accidental toggle. Prefer `.onPlayPauseCommand` for deliberate intent.
- **Do NOT change focus without user interaction.** Focus should only move as a result of a user gesture.

### Focus engine — HIG rules

- **Rely on system-provided focus effects.** Do not build fully custom focus rings unless absolutely necessary. The system's parallax/scale effect is the expected affordance.
- **Every interactive element must be reachable by D-pad.** Unlike iPadOS (Tab key groups), tvOS uses directional focus to reach every element — nothing can be pointer-only.
- **Design for 5 focus states**: unfocused, focused (elevated + lit), highlighted (press feedback), selected, unavailable. Supply larger assets for the focused size to stay sharp.
- **In full-screen experiences, gestures affect content — not focus.** The player should handle D-pad as seek/control, not focus movement. This is consistent with our current `.focusable()` + `.onMoveCommand` approach.
- **Avoid a pointer.** Free-form cursor movement is not appropriate for menu/browse UI.

### Layout & typography — 10-foot rules

- Viewers sit **8+ feet** from screen. Everything must be readable at that distance.
- Minimum body text: **≥ 30 pt** (SF Pro Display). Our current `.caption` and `.subheadline` use in video cards is too small.
- Support **edge-to-edge artwork** — full-bleed thumbnails / hero images are encouraged.
- Use tvOS **safe area** for text/controls; overscan can clip content on older TVs.
- SF Symbols scale automatically — prefer them over custom icons.

### Content & cinematic experience

- "Deliver beautiful, edge-to-edge artwork, subtle and fluid animations, and engaging audio, wrapping people in a rich, cinematic experience." — HIG Designing for tvOS
- Transitions should be fluid and not jarring. Use `.animation(.easeInOut)` consistently.
- **Dark backgrounds** are the default on tvOS; light UI is jarring on a large TV in a darkened room.

### Multiuser support

- Apple TV is a **shared device**. The HIG emphasises making sign-in easy and infrequent, and supporting profile switching.
- Our device-code + QR sign-in is already the TV-native pattern — no change needed there.

### System integrations worth adding

| Feature | HIG reference | Priority |
|---|---|---|
| **Top Shelf Extension** | [Top Shelf HIG](https://developer.apple.com/design/human-interface-guidelines/top-shelf) | Medium (Phase TV-4) |
| **Siri / INPlayMediaIntent** | Siri HIG | Low (Phase TV-5) |
| **Now Playing info** (lock screen / Control Center) | `MPNowPlayingInfoCenter` | High — already partially in `PlaybackViewModel` via `updateNowPlayingPlayback()` |
| **SharePlay** | SharePlay HIG | Low |
