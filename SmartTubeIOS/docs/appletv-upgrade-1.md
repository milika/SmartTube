# SmartTube tvOS — Upgrade Plan 1

> Upgrade wave driven by Apple HIG audit (April 2026).
> All items here are improvements to the *already-working* tvOS target.
> This is not the initial port plan — see `appletv.md` for that.

---

## Context

The tvOS target builds and runs. Core playback works: video loads, plays, pauses, seeks ±10 s, Menu dismisses. The focus chain (Tab bar → Chips → Video list) is functional and covered by UI tests.

This plan addresses the gap between "it works" and "it feels native to Apple TV" based on reading the HIG.

---

## Issues identified from HIG audit

### 1. Player — tap-to-toggle is risky on tvOS (HIG: avoid inadvertent taps)

**HIG quote:** "Keep in mind that people might cause an inadvertent tap when they rest a thumb on the remote, pick it up, move it around, or hand it to someone else, so it often works well to avoid responding to taps during live video playback."

**Current state:** `.onTapGesture` on the player's focusable container fires `togglePlayPause()` on every select press, including accidental resting-thumb taps.

**Fix:** Remove `.onTapGesture` from the player. Use only `.onPlayPauseCommand` for play/pause. If a visual "press select to pause" affordance is needed, show it in the controls overlay triggered by a D-pad up/down press.

---

### 2. Typography — video cards and UI use iOS-scale fonts (HIG: ≥30 pt body at 10 feet)

**HIG rule:** Viewers sit 8+ feet away. Text must be legible at that distance. Minimum body text ≈ 30 pt.

**Current problems:**
- `VideoCardView` title uses `.caption` (12 pt on iOS → unreadable at 10 ft)
- Chip bar uses `.subheadline` (15 pt)
- Player time labels use `.callout` (16 pt) / `.body` (17 pt) — borderline
- Channel name, view count, duration badge: all iOS compact sizes

**Fix:** Add a tvOS font scale modifier. Define `Font` extensions or a `tvOSFont(_ style:)` helper that returns larger sizes on tvOS:

```swift
// Proposed tvOS font sizes (SF Pro Display)
.caption   → 24 pt   (was 12 pt)
.callout   → 28 pt   (was 16 pt)
.body      → 32 pt   (was 17 pt)
.title3    → 40 pt   (was 20 pt)
.title2    → 48 pt   (was 22 pt)
.title     → 56 pt   (was 28 pt)
.largeTitle → 64 pt  (was 34 pt)
```

Apply via `#if os(tvOS)` at the view-modifier level, not by changing shared model code.

---

### 3. Focus effects — custom ring duplicates (but diverges from) system behaviour

**HIG rule:** "Rely on system-provided focus effects. System-defined focus effects are precisely tuned." Custom focus effects should only be used when absolutely necessary.

**Current state:** `VideoCardView` draws a manual white `strokeBorder` ring + shadow + scale effect via `@FocusState`. This is functional but:
- Does not use the system parallax depth effect
- May look inconsistent with other tvOS apps
- Scale + shadow is not the system-default "card" elevation effect

**Fix (two options — choose one):**
- **Option A (recommended):** Replace the custom ring with `.buttonStyle(.card)` on the wrapping `Button` in `HomeView`. The system Card button style on tvOS gives the correct focused elevation, depth, and parallax for free. Remove custom `@FocusState` ring from `VideoCardView`.
- **Option B (keep custom, refine):** Keep `@FocusState` but drop the `strokeBorder` ring — instead apply only scale + drop shadow to match the system card look without the iOS-style focus ring that tvOS does not use natively.

---

### 4. Player scrubbing — official Apple model not implemented

**Apple support page (tvOS 26):** The official scrub flow is:
1. Press ⏯ to **pause**.
2. **Swipe left or right** on the clickpad / touch surface — a **preview thumbnail** appears above the timeline showing the target position.
3. For more precision: circle finger around the clickpad ring (silver remote only).
4. **Confirm** at new position: press ⏯. **Cancel** (return to original): press Menu or ⏯.

**HIG quote:** "People press before swiping to activate scrubbing mode."

**Current state:** D-pad left/right does ±10 s instant skip. This mirrors the Apple-defined *skip* behaviour (press left/right on clickpad ring = 10 s skip) but is not the full *scrub* UX. We have no preview thumbnail and no swipe-drag scrub mode. The custom progress bar is displayed but the touch-surface swipe gesture is not connected to it.

**Fix options:**
- **Option A — adopt `AVPlayerViewController` on tvOS (highest fidelity):** Wrap `AVPlayerViewController` in `UIViewRepresentable` for the tvOS player path. Gets system scrubbing (pause → swipe → thumbnail preview → confirm), chapter markers, subtitle tray, and system transport controls for free. Keeps the bare `AVPlayerLayer` on iOS for XCUITest compatibility.
- **Option B — implement swipe scrub in custom player (medium effort):** Add `DragGesture` on the player's focusable container (tvOS touch surface sends `DragGesture` events). On drag: enter scrub mode, update `scrubTime`, show thumbnail position in `tvProgressBar`. On release: commit seek. Hold left/right for 2×/3×/4× continuous FF/RW (this is actually the *official* Apple clickpad ring behaviour).
- **Option C — keep ±10 s skip only (current state):** Simplest; implements Apple's skip gesture correctly; lacks full scrub timeline drag.

Recommended: **Option A** for a production release. Option C is acceptable for now.

---

### 4b. Player — skip backward does not auto-enable subtitles

**Apple support page (tvOS 26):** "When you skip backward 10 seconds, subtitles are turned on automatically so that you can rewatch that section with subtitles."

**Current state:** Our `seekRelative(seconds: -10)` implementation seeks but does not touch subtitle state. The system `AVPlayerViewController` handles this automatically. Our custom player path does not.

**Fix:** After a backward seek in the tvOS player, call the subtitle-enable path if subtitles are available. If adopting `AVPlayerViewController` (Option A above), this is free.

Priority: Low (nice-to-have; only relevant once subtitles are fully wired).

---

### 5. Back button — game-style pause menu vs immediate dismiss

**HIG quote:** "In almost all cases, open the parent of the current screen when people press the Back button."

**Current state:** `.onExitCommand` immediately calls `vm.stop()` + `dismiss()` — correct per HIG. No issue here, but note:

- The HIG exception is for *games* to show a pause menu instead of exiting. SmartTube is a video player, so immediate back is correct.
- However, if playback is mid-video, it may be worth confirming "Are you sure?" to avoid accidental back-presses. Android SmartTube does not do this; we won't add it unless requested.

**Status: no change needed.**

---

### 6. Focus — every interactive element must be reachable (HIG requirement)

**HIG rule:** "tvOS users rely on directional gestures on a remote to reach every onscreen element."

**Elements to audit:**
- Like / Dislike buttons in player controls overlay
- Speed picker (currently a SwiftUI sheet / popover)
- Quality picker (currently a SwiftUI sheet / popover)
- More menu (currently a SwiftUI sheet)
- Chapter list (if/when shown)
- Subscribe button on channel views

Sheets and popovers do work on tvOS (the system presents them and they are focus-traversable), but they need to be tested to confirm focus enters them correctly and Menu/back dismisses them.

---

### 7. Now Playing metadata — MPNowPlayingInfoCenter completeness

`PlaybackViewModel.updateNowPlayingPlayback()` exists but the content of the metadata dict needs auditing. Apple TV Control Center and the Remote app both read this. Required fields:

- `MPMediaItemPropertyTitle` — video title
- `MPMediaItemPropertyArtist` — channel name
- `MPMediaItemPropertyArtwork` — thumbnail (as `MPMediaItemArtwork`)
- `MPNowPlayingInfoPropertyElapsedPlaybackTime` — currentTime
- `MPMediaItemPropertyPlaybackDuration` — duration
- `MPNowPlayingInfoPropertyPlaybackRate` — 1.0 or 0.0

Missing artwork is a common gap. Add async thumbnail fetch → `MPMediaItemArtwork`.

---

### 8. Layout — safe area / overscan on older TVs

tvOS safe area insets account for TV overscan. `ignoresSafeArea()` is used on the player background (correct — video should be edge-to-edge), but UI controls (time labels, progress bar, back button) must be inside the safe area.

**Current state:** Player progress bar uses `hPad: 40`. The `.topLeading` overlay for the back button uses `.padding(.top, 60)`. These may clip on older displays.

**Fix:** Replace hardcoded padding with `.padding(geo.safeAreaInsets)` or use `.safeAreaPadding()` modifier on controls.

---

## Prioritised backlog

| # | Item | HIG source | Effort | Priority |
|---|------|-----------|--------|----------|
| 1 | Remove `.onTapGesture` from player (inadvertent tap) | Remotes HIG | XS | **High** |
| 2 | Typography — tvOS font scale across all views | Designing for tvOS | M | **High** |
| 3 | `VideoCardView` — switch to `.buttonStyle(.card)` | Focus HIG | S | **High** |
| 4 | Player — `AVPlayerViewController` on tvOS (system scrub + thumbnail preview + subtitle tray) | Support page / HIG | L | Medium |
| 4b | Skip backward auto-enables subtitles | Support page | S | Low |
| 5 | Audit focus reachability of all player overlay controls | Focus HIG | S | Medium |
| 6 | `MPNowPlayingInfoCenter` — add thumbnail artwork | Now Playing | S | Medium |
| 7 | Safe area — replace hardcoded padding in player | Layout | S | Medium |
| 8 | Player scrub — swipe `DragGesture` + thumbnail preview if staying on custom player | Support page | M | Low |
| 9 | Top Shelf Extension | Top Shelf HIG | L | Low |
| 10 | Siri / `INPlayMediaIntent` | Siri HIG | L | Low |

---

## Implementation order (suggested sprints)

### Sprint A — Quick wins (no architectural change)

1. **Remove `.onTapGesture`** from player — 5 min
2. **Font scaling** — add `#if os(tvOS)` font modifiers to `VideoCardView`, chip buttons, player labels — 2 h
3. **Safe area padding** in player controls — 30 min

### Sprint B — Focus polish

4. **`.buttonStyle(.card)`** on video card buttons in `HomeView` / `BrowseView` — 1 h
5. **Focus audit** of player overlay (like/dislike, speed, quality, more menu) — 2 h
6. **`MPNowPlayingInfoCenter` thumbnail** — async fetch + `MPMediaItemArtwork` — 1 h

### Sprint C — Scrubbing (medium effort)

7. **`AVPlayerViewController` on tvOS** — new `TVPlayerView` using `UIViewRepresentable` wrapping `AVPlayerViewController`, conditionally shown instead of `PlayerView` on tvOS — 4 h + testing

### Sprint D — System integrations (low priority)

8. Top Shelf Extension
9. Siri Intent

---

## Non-goals for this upgrade wave

- Shorts swipe player (already planned as Option B in `appletv.md` Phase TV-3)
- Game controller support (not the target use case)
- Localization / RTL layout
- Multi-user profile switching UI
