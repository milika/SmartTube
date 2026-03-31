# Android Repository References

These are the original Android-based repositories that SmartTube was built on.
They are preserved here for reference — useful if any business logic, API handling, or protocol details need to be consulted during iOS development.

## Original SmartTube Android App
- **Repo:** https://github.com/yuliskov/SmartTube
- The main Android TV app. Entry point is `smarttubetv/`. Uses Leanback UI, ExoPlayer, and the libs below.

## MediaServiceCore (Android submodule)
- **Repo:** https://github.com/yuliskov/MediaServiceCore
- Contains the YouTube API client, media service interfaces (`mediaserviceinterfaces/`), and `youtubeapi/` module.
- This is the primary source of truth for YouTube API integration logic, parsing, and playback URLs.

## SharedModules (Android submodule)
- **Repo:** https://github.com/yuliskov/SharedModules
- Shared Gradle/build infrastructure and common utilities used across MediaServiceCore and smarttubetv.

## Notable Android Libraries Bundled
| Directory | Purpose |
|---|---|
| `exoplayer-amzn-2.10.6/` | Amazon-patched ExoPlayer 2.10.6 for DASH/HLS playback |
| `chatkit/` | Live chat UI rendering |
| `common/` | App-level shared code (settings, preferences, UI utils) |
| `leanback-1.0.0/` | Android TV Leanback UI components |
| `leanbackassistant/` | Voice/assistant integration for Leanback |
| `fragment-1.1.0/` | Patched AndroidX Fragment library |
| `filepicker-lib/` | File picker for local media |
| `doubletapplayerview/` | Double-tap seek gesture overlay |
| `slidableactivity/` | Slide-to-dismiss activity gesture |

## To Clone Android Codebase
```bash
git clone https://github.com/yuliskov/SmartTube android-smarttube
cd android-smarttube
git submodule update --init --recursive
```
