# UI Test Authoring Patterns

## Basic test class setup

Always set `continueAfterFailure = false` in `setUpWithError`. Use the
`--uitesting` launch argument so the app can skip unnecessary animations:

```swift
final class MyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }
}
```

---

## Navigating tabs

SmartTube uses a tab bar with buttons labelled "Home", "Search", "Library", etc.
Always wait for the tab button before tapping:

```swift
let homeTab = app.tabBars.buttons["Home"]
XCTAssertTrue(homeTab.waitForExistence(timeout: 5))
homeTab.tap()
```

---

## Waiting for a network-loaded feed to settle

After tapping a chip or navigating to a feed, use a fixed sleep rather than
a complex descendant-traversal predicate. Descendant queries (`BEGINSWITH ...`)
inside `XCTNSPredicateExpectation` closures trigger XCTest snapshot timeouts
during active view-hierarchy transitions:

```swift
// Preferred — avoids snapshot timeouts
private func waitForFeedToSettle() {
    Thread.sleep(forTimeInterval: 5)
}
```

Alternatively, wait for the loading spinner to disappear:

```swift
let spinner = app.activityIndicators.firstMatch
if spinner.waitForExistence(timeout: 3) {
    let gone = NSPredicate(format: "exists == false")
    _ = XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: gone, object: spinner)],
        timeout: 15
    )
}
```

---

## Scrolling a horizontal chip/tab bar

Use **container-relative coordinates** so gestures always land on the bar
regardless of its vertical position on screen:

```swift
let near = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
let far  = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))

// Reveal trailing chips
far.press(forDuration: 0.05, thenDragTo: near)

// Return to leading chips
near.press(forDuration: 0.05, thenDragTo: far)
```

---

## Tapping a chip that may be partially off-screen

DO NOT call `.isHittable` or `.tap()` before the element is fully in the
viewport — both throw "Activation point invalid" for clipped elements.
Use `element.frame` (safe for off-screen elements) to decide scroll direction:

```swift
let screenWidth = app.windows.firstMatch.frame.width
for _ in 0..<8 {
    let frame = chip.frame
    guard frame.origin.x < 4 || frame.maxX > screenWidth - 4 else { break }
    if frame.origin.x < 4 {
        near.press(forDuration: 0.05, thenDragTo: far)  // scroll right
    } else {
        far.press(forDuration: 0.05, thenDragTo: near)  // scroll left
    }
}
chip.tap()  // element is now fully on screen
```

---

## Asserting absence of a network error

`BrowseViewModel` sets `vm.error` for any non-auth HTTP failure; `BrowseView`
presents it as `alert("Error", ...)`. Use this as a proxy for HTTP error detection:

```swift
waitForFeedToSettle()
let errorAlert = app.alerts["Error"]
XCTAssertFalse(
    errorAlert.exists,
    "An 'Error' alert appeared — HTTP error returned for '\(chipName)' chip"
)
// Dismiss anyway so subsequent chips can still run
if errorAlert.exists { errorAlert.buttons.firstMatch.tap() }
```

---

## Accessibility identifiers

The app uses `accessibilityIdentifier` on key elements. Use them in tests:

| Identifier | Element |
|---|---|
| `home.chipBar` | Horizontal chip ScrollView on Home tab |
| `video.card.<videoId>` | Individual video card in feeds |
| `player.titleLabel` | Video title overlay in PlayerView |
| `library.sectionPicker` | Segmented control on Library tab |

Use `XcodeGrep` to discover other identifiers:
```
mcp_xcode_XcodeGrep(tabIdentifier: "<tab>", pattern: "accessibilityIdentifier", glob: "**/*.swift")
```

---

## Triggering player swipe gestures

The player's swipe overlay is a UIKit `UIPanGestureRecognizer`. Trigger it
with a coordinate-based press-drag rather than `swipeLeft()`/`swipeRight()`:

```swift
// Swipe left -> play next related video
let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
start.press(forDuration: 0.05, thenDragTo: end)

// Swipe right -> go back to previous video
let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
start.press(forDuration: 0.05, thenDragTo: end)
```
