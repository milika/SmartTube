# SmartTube

A native Swift/SwiftUI YouTube client for **iPhone**, **iPad**, and **macOS** (Catalyst / native macOS 13+).

Inspired by the original [SmartTube Android app](https://github.com/yuliskov/SmartTube) — see [SmartTubeIOS/docs/android-repos.md](SmartTubeIOS/docs/android-repos.md) for Android repo references.

> **tvOS is intentionally out of scope.** A native SwiftUI adaptive layout is used rather than replicating the Android TV Leanback UI.

---

## Features

- Home, Subscriptions, History, and Search feeds
- Video playback via AVPlayer — adaptive HLS/DASH, up to 8K
- SponsorBlock integration with auto-skip
- DeArrow community titles and thumbnails
- Google OAuth sign-in
- Picture-in-Picture
- Settings: quality, playback speed, theme, SponsorBlock categories
- No ads, no tracking

---

## Project Structure

```
SmartTubeIOS/          Swift Package — core library (networking, models, services, views)
SmartTubeApp/          Xcode app target (XcodeGen project.yml)
SmartTube.xcworkspace/ Xcode workspace
```

Full architecture docs: [SmartTubeIOS/docs/](SmartTubeIOS/docs/)

---

## Requirements

| Platform | Minimum |
|---|---|
| iOS / iPadOS | 17.0 |
| macOS | 14.0 (Sonoma) |
| Xcode | 16.0 |
| Swift | 6.0 |

---

## Getting Started

```bash
git clone https://github.com/yuliskov/SmartTube
cd SmartTube
open SmartTube.xcworkspace
```

Select the **SmartTube** scheme and run.

---

## License

[GPL-3.0](LICENSE)
