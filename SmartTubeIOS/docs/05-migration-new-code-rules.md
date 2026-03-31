# Migration Plan — Adopt New Swift Code Rules

> **Status key:** ✅ Done · 🔲 Not started · 🚧 Partial  
> **Reference rules:** `.github/swift.instructions.md` · `.github/skills/swift-concurrency/SKILL.md`  
> **Audited:** 2026-03-31

---

## Overview

This document tracks migration of the existing iOS codebase to the rules enforced by `.github/swift.instructions.md`. Violations are grouped by phase, ordered by severity and dependency.

Each phase is independently shippable (builds and passes tests before moving forward).

---

## Phase 1 — Security & Swift 6 Foundation

> These are blockers for all other phases. Fix before any feature work.

### 1.1 Move OAuth tokens to Keychain 🔲
**File:** `Sources/SmartTubeIOS/Services/AuthService.swift`  
**Violation:** `saveToKeychain()` / `loadFromKeychain()` store `accessToken` and `refreshToken` in `UserDefaults`. This is a CWE-312 / OWASP M2 vulnerability — `UserDefaults` is unencrypted and readable by other processes.  
**Fix:** Replace `UserDefaults` reads/writes for `accessToken`, `refreshToken`, `expiresAt`, and `userId` with `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` calls using `kSecClassGenericPassword`.  
**Acceptance criteria:**
- Tokens are no longer written to `UserDefaults`
- App still signs in successfully after cold launch
- Removing app from device deletes the Keychain items (set `kSecAttrAccessible` to `kSecAttrAccessibleAfterFirstUnlock`)

---

### 1.2 Enable Swift 6 Language Mode 🔲
**File:** `Package.swift`  
**Violation:** `swift-tools-version: 5.9`, no `swiftLanguageVersions` set. No strict concurrency settings on any target. All data-race, Sendable, and actor-isolation checks are suppressed.  
**Fix:** 
1. Bump tools version header to `// swift-tools-version: 6.0`
2. Add `.swiftLanguageVersion(.v6)` to `swiftSettings` on every target
3. Compile — all remaining phases will be needed to make the build green

**Acceptance criteria:**
- `Package.swift` targets compile under Swift 6 mode
- No new warnings suppressed with `@unchecked Sendable` without a documented safety invariant

---

## Phase 2 — Replace ObservableObject with @Observable

> All seven view-model and service classes use the deprecated `ObservableObject` + `@Published` pattern. This phase migrates them to the `@Observable` macro (Swift 5.9+, iOS 17+). All downstream SwiftUI property-wrapper changes cascade automatically.

**Order matters:** migrate leaf dependencies first (services before view models, view models before views).

### 2.1 Migrate `SettingsStore` 🔲
**File:** `Sources/SmartTubeIOS/Services/SettingsStore.swift`  
**Violations:**
- `final class SettingsStore: ObservableObject`
- `@Published public var settings: AppSettings`

**Fix:**
```swift
// Before
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings = .init()
}

// After
@Observable
public final class SettingsStore {
    public var settings: AppSettings = .init()
}
```
Remove `import Combine` if it becomes unused.

---

### 2.2 Migrate `AuthService` 🔲
**File:** `Sources/SmartTubeIOS/Services/AuthService.swift`  
**Violations:**
- `final class AuthService: ObservableObject`
- 6× `@Published` properties

**Fix:** Add `@Observable`, drop `ObservableObject` conformance, remove all `@Published` annotations, remove `import Combine`.  
Note: `@MainActor` must be retained on the class (it is UI-observable state).

---

### 2.3 Migrate `HomeViewModel` 🔲
**File:** `Sources/SmartTubeIOS/ViewModels/HomeViewModel.swift`  
**Violations:** `ObservableObject`, 2× `@Published`  
**Fix:** Same pattern as 2.1.

---

### 2.4 Migrate `BrowseViewModel` 🔲
**File:** `Sources/SmartTubeIOS/ViewModels/BrowseViewModel.swift`  
**Violations:** `ObservableObject`, 6× `@Published`  
**Fix:** Same pattern. Also remove the `print()` call at line ~89 (use `Logger` / OSLog or remove — OSLog already covers this).

---

### 2.5 Migrate `SearchViewModel` + `ChannelViewModel` 🔲
**File:** `Sources/SmartTubeIOS/ViewModels/SearchViewModel.swift`  
**Violations:** `ObservableObject`, 5× `@Published`, `ChannelViewModel: ObservableObject`, 3× `@Published`  
**Additional violation:** Combine debounce pipeline (`$query.debounce(...).sink { ... }`) must be replaced with structured concurrency.

**Fix for debounce pipeline:**
```swift
// Before (Combine)
$query.removeDuplicates()
    .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
    .sink { [weak self] q in Task { await self?.loadSuggestions(for: q) } }
    .store(in: &cancellables)

// After (AsyncStream + Task.sleep)
// In .task(id: query) view modifier:
.task(id: query) {
    try? await Task.sleep(for: .milliseconds(300))
    await loadSuggestions(for: query)
}
```
Remove `import Combine` and `Set<AnyCancellable>`.

---

### 2.6 Migrate `PlaybackViewModel` 🔲
**File:** `Sources/SmartTubeIOS/ViewModels/PlaybackViewModel.swift`  
**Violations:** `ObservableObject`, 10× `@Published`, 2× `AnyCancellable` for AVPlayer observation, `DispatchQueue.main` in `addPeriodicTimeObserver`.

**Fix Combine AVPlayer observation → AsyncStream:**
```swift
// Before (Combine)
statusObserver = player.publisher(for: \.currentItem?.status)
    .receive(on: RunLoop.main)
    .sink { [weak self] status in ... }

// After (AsyncStream)
for await status in player.statusStream {
    await handleStatus(status)
}
```

**Fix periodic time observer:**
```swift
// Before
player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in ... }

// After
Task { @MainActor in
    for await time in player.periodicTimeStream(interval: interval) {
        updateProgress(time)
    }
}
```

Remove `import Combine`.

---

### 2.7 Update SwiftUI call sites 🔲
**Files:** `AppEntry.swift`, `SmartTubeApp.swift`, `RootView.swift`, `HomeView.swift`, `PlayerView.swift`, `ChannelView.swift`, `SignInView.swift`, `BrowseView.swift`, `LibraryView.swift`, `SearchView.swift`, `SettingsView.swift`  

**Pattern changes:**

| Before | After |
|--------|-------|
| `@StateObject private var vm = ViewModel()` | `@State private var vm = ViewModel()` |
| `@ObservedObject var vm: ViewModel` | pass directly as `let vm: ViewModel` |
| `@EnvironmentObject private var auth: AuthService` | `@Environment(AuthService.self) private var auth` |
| `.environmentObject(auth)` | `.environment(auth)` |

Remove all `import Combine` in view files once `ObservableObject` types are gone.

---

## Phase 3 — Replace DispatchQueue with Actors and Structured Concurrency

### 3.1 Refactor `VideoStateStore` to an `actor` 🔲
**File:** `Sources/SmartTubeIOSCore/VideoStateStore.swift`  
**Violations:** `DispatchQueue(label:)` used as manual synchronization, `queue.sync`, `queue.async`.  
**Fix:** Convert to `actor`, make `state(for:)`, `save(videoId:...)`, and `clear(videoId:)` `async`.

```swift
// Before
public final class VideoStateStore {
    private let queue = DispatchQueue(label: "com.smarttube.videostate", qos: .utility)
    public static let shared = VideoStateStore()
    func state(for videoId: String) -> State? {
        queue.sync { states[videoId] }
    }
}

// After
public actor VideoStateStore {
    public static let shared = VideoStateStore()
    func state(for videoId: String) -> State? { states[videoId] }
    func save(videoId: String, state: State) { ... }
    func clear(videoId: String) { ... }
}
```

Update all call sites to `await VideoStateStore.shared.state(for:)`.

---

### 3.2 Replace `DispatchQueue.main.asyncAfter` in `CountdownView` 🔲
**File:** `Sources/SmartTubeIOS/Views/Common/SignInView.swift`  
**Violation:** Recursive `DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick() }` timer.  
**Fix:** Replace with `.task` modifier + `Task.sleep`:

```swift
// Before
func tick() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        secondsRemaining -= 1
        if secondsRemaining > 0 { tick() }
    }
}
.onAppear { tick() }

// After
.task {
    while secondsRemaining > 0 {
        try? await Task.sleep(for: .seconds(1))
        secondsRemaining -= 1
    }
}
```

---

## Phase 4 — Remove Force Unwraps

### 4.1 Fix force unwraps in `InnerTubeAPI` 🔲
**File:** `Sources/SmartTubeIOSCore/InnerTubeAPI.swift`  
**Violations:** `URLComponents(...)!` and `URLRequest(url: comps.url!)` in `post()`, `postPlayer()`, and `postTV()`.  
**Fix:** Replace with `guard let` + throw a typed error:

```swift
guard let comps = URLComponents(string: baseURL + endpoint),
      let url = comps.url else {
    throw APIError.invalidURL(baseURL + endpoint)
}
```

---

### 4.2 Fix force unwrap in `AuthService` 🔲
**File:** `Sources/SmartTubeIOS/Services/AuthService.swift`  
**Violation:** `URL(string: "https://yt.be/activate")!`  
**Fix:** This is a static literal — safe to use `URL(staticString:)` initializer. Or store as a `static let` with a `guard`.

```swift
// Before
let activationURL = URL(string: "https://yt.be/activate")!

// After
static let activationURL = URL(string: "https://yt.be/activate")! // static literal — safe
// Or use:
static let activationURL: URL = URL(staticString: "https://yt.be/activate")
```

---

### 4.3 Fix force unwrap in `VideoCardView` 🔲
**File:** `Sources/SmartTubeIOS/Views/Browse/VideoCardView.swift`  
**Violation:** `ShareLink(item: URL(string: "...")!)`  
**Fix:** Use optional chaining and hide the share button if URL is nil:

```swift
if let shareURL = URL(string: shareURLString) {
    ShareLink(item: shareURL)
}
```

---

## Phase 5 — Remove `print()` Logging

### 5.1 Remove `print()` calls 🔲
**Files:** `InnerTubeAPI.swift`, `BrowseViewModel.swift`  
**Violation:** `print(...)` statements alongside existing `OSLog`/`Logger` usage.  
**Fix:** Delete the `print()` lines. OSLog already captures the same info.

---

## Phase 6 — Should-Fix: Typed Throws, Sendable, and DocC

> Lower priority. These do not affect functionality but are required by the code rules. Can be done incrementally alongside feature work.

### 6.1 Add typed throws 🔲
**Files:** `InnerTubeAPI.swift`, `AuthService.swift`  
Replace bare `throws` with typed variants on public throwing functions:
- `fetchHome() async throws` → `throws(APIError)`
- `validAccessToken() async throws` → `throws(AuthError)`
- etc.

---

### 6.2 Add `Sendable` conformance 🔲
**Files:** `VideoGroup.swift`, `SponsorBlockService.swift`, `AuthService.swift`  
Add explicit `: Sendable` to value types (`VideoGroup`, `VideoGroup.Action`, `VideoGroup.Layout`, `BrowseSection.SectionType`, `BrandingInfo`, `ActivationInfo`) that cross actor/task boundaries.

---

### 6.3 Add DocC `///` documentation to all public APIs 🔲
**Files:** All files in `Sources/SmartTubeIOSCore/` and public members of service/view-model files.  
Add `/// - Parameter`, `/// - Returns`, `/// - Throws` markup to all public `func`, `var`, and `struct`/`class`/`actor` declarations.

---

## Dependency Map

```
Phase 1 (Security + Swift 6) ──► must complete first
    │
    ▼
Phase 2 (ObservableObject → @Observable)
    │   ├─ 2.1 SettingsStore
    │   ├─ 2.2 AuthService
    │   ├─ 2.3 HomeViewModel
    │   ├─ 2.4 BrowseViewModel
    │   ├─ 2.5 SearchViewModel + ChannelViewModel
    │   ├─ 2.6 PlaybackViewModel
    │   └─ 2.7 SwiftUI call sites  ◄── depends on 2.1–2.6
    │
Phase 3 (DispatchQueue → actors/structured concurrency) — parallel with Phase 2
Phase 4 (Force unwraps) — parallel with Phase 2
Phase 5 (print() removal) — parallel, trivial
    │
    ▼
Phase 6 (Typed throws, Sendable, DocC) — ongoing, parallel with feature work
```

---

## Checklist Summary

| # | Task | File(s) | Priority | Status |
|---|------|---------|----------|--------|
| 1.1 | Move OAuth tokens to Keychain | `AuthService.swift` | 🔴 Critical Security | ✅ |
| 1.2 | Enable Swift 6 language mode | `Package.swift` | 🔴 Must | ✅ |
| 2.1 | `SettingsStore` → `@Observable` | `SettingsStore.swift` | 🔴 Must | ✅ |
| 2.2 | `AuthService` → `@Observable` | `AuthService.swift` | 🔴 Must | ✅ |
| 2.3 | `HomeViewModel` → `@Observable` | `HomeViewModel.swift` | 🔴 Must | ✅ |
| 2.4 | `BrowseViewModel` → `@Observable` | `BrowseViewModel.swift` | 🔴 Must | ✅ |
| 2.5 | `SearchViewModel`/`ChannelViewModel` → `@Observable` + async debounce | `SearchViewModel.swift` | 🔴 Must | ✅ |
| 2.6 | `PlaybackViewModel` → `@Observable` + async AVPlayer streams | `PlaybackViewModel.swift` | 🔴 Must | ✅ |
| 2.7 | Update all SwiftUI call sites | Multiple view files | 🔴 Must | ✅ |
| 3.1 | `VideoStateStore` → `actor` | `VideoStateStore.swift` | 🔴 Must | ✅ |
| 3.2 | `CountdownView` timer → `Task.sleep` | `SignInView.swift` | 🔴 Must | ✅ |
| 4.1 | Fix `InnerTubeAPI` force unwraps | `InnerTubeAPI.swift` | 🔴 Must | ✅ |
| 4.2 | Fix `AuthService` force unwrap | `AuthService.swift` | 🔴 Must | ✅ |
| 4.3 | Fix `VideoCardView` force unwrap | `VideoCardView.swift` | 🔴 Must | ✅ |
| 5.1 | Remove `print()` calls | `InnerTubeAPI.swift`, `BrowseViewModel.swift` | 🔴 Must | ✅ |
| 6.1 | Add typed throws | `InnerTubeAPI.swift`, `AuthService.swift` | 🟡 Should | 🔲 |
| 6.2 | Add `Sendable` conformance | `VideoGroup.swift`, `SponsorBlockService.swift`, `AuthService.swift` | 🟡 Should | ✅ |
| 6.3 | Add DocC `///` documentation | All public API files | 🟡 Should | 🔲 |
