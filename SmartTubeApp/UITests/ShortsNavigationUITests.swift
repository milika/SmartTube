import XCTest

// MARK: - ShortsNavigationUITests
//
// Full-app UI tests that launch SmartTube, navigate to the Home tab,
// select the Shorts chip, and assert that the Shorts feed is visible.
//
// Requirements: run on an iOS 17+ simulator with the SmartTube scheme selected.
// The test uses the XCUIApplication API — no live network calls are made;
// the app will show the empty / sign-in state which is sufficient for navigation.

final class ShortsNavigationUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Inject a launch argument so the app can skip animations in tests.
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Scrolls the horizontal chip bar left by performing coordinate-based swipes
    /// near the top of the screen where the chip bar lives.
    private func scrollToShortsChip() {
        // dy ≈ 0.09 places the gesture in the chip bar area (~72pt from the top).
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.09))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.09))
        for _ in 0..<3 {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    // MARK: - Tests

    /// Verifies the root window exists immediately after launch.
    func testAppLaunchesSuccessfully() {
        XCTAssertTrue(app.windows.firstMatch.exists, "App window should exist after launch")
    }

    func testNavigateToHomeTab() {
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5), "Home tab should be visible in the tab bar")
        homeTab.tap()

        // After tapping Home, the chip bar should appear with section chips.
        let shortsChip = app.buttons["Shorts"]
        XCTAssertTrue(shortsChip.waitForExistence(timeout: 5), "Shorts chip should be visible in the Home chip bar")
    }

    func testShortsChipIsReachable() {
        // Navigate to Home tab first.
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5))
        homeTab.tap()

        // Tap the Shorts chip in the horizontal chip bar.
        let shortsChip = app.buttons["Shorts"]
        XCTAssertTrue(shortsChip.waitForExistence(timeout: 5), "Shorts chip should exist in the Home chip bar")
        scrollToShortsChip()
        shortsChip.tap()

        // The Shorts chip should now be selected (filled background).
        XCTAssertTrue(
            shortsChip.isSelected,
            "Shorts chip should be selected after tap"
        )
    }

    func testShortsScreenShowsContentOrEmptyState() {
        // Navigate to Home → Shorts.
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5))
        homeTab.tap()

        let shortsChip = app.buttons["Shorts"]
        XCTAssertTrue(shortsChip.waitForExistence(timeout: 5))
        scrollToShortsChip()
        shortsChip.tap()

        // Allow time for any loading animation to settle.
        let contentOrEmpty = app.scrollViews.firstMatch.waitForExistence(timeout: 5)
            || app.staticTexts["Nothing here yet"].waitForExistence(timeout: 5)
            || app.staticTexts["Sign in to see your library"].waitForExistence(timeout: 5)

        XCTAssertTrue(contentOrEmpty, "Shorts screen should show content, an empty state, or a sign-in prompt")
    }

    // MARK: - Smoke test

    func testNavigationDoesNotCrash() {
        // A simple smoke test: navigate all the way to Shorts without crashing.
        let homeTab = app.tabBars.buttons["Home"]
        guard homeTab.waitForExistence(timeout: 5) else {
            XCTFail("Home tab not found")
            return
        }
        homeTab.tap()

        let shortsChip = app.buttons["Shorts"]
        guard shortsChip.waitForExistence(timeout: 5) else {
            XCTFail("Shorts chip not found")
            return
        }
        scrollToShortsChip()
        shortsChip.tap()

        // Pause briefly to let the view settle, then assert no crash occurred.
        _ = app.scrollViews.firstMatch.waitForExistence(timeout: 3)
        XCTAssertTrue(app.windows.firstMatch.exists, "App should still be running after navigating to Shorts")
    }
}

// MARK: - ShortsSwipeUITests
//
// Full-app UI tests that exercise swipe-up / swipe-down gesture navigation
// inside ShortsPlayerView.
//
// Setup: the app is launched with `--uitesting-shorts` which bypasses the full
// navigation stack and presents ShortsPlayerView directly with three stub shorts
// (Short One, Short Two, Short Three). No network calls or sign-in required.
//
// The index label `shorts.indexLabel` shows "N / 3" and is the primary assertion
// target: if the swipe registered, the label changes.

final class ShortsSwipeUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-shorts"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Performs initial setup: waits for the shorts player to be on screen.
    /// Returns the window element used for swipe gestures.
    private func openControls() -> XCUIElement {
        // The index label is always visible — wait for it as the ready signal.
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 5), "Index label should appear on launch")
        return app.windows.firstMatch
    }

    private var indexLabel: XCUIElement {
        app.staticTexts["shorts.indexLabel"].firstMatch
    }

    private enum SwipeDirection { case up, down }

    private func swipe(_ direction: SwipeDirection, on element: XCUIElement) {
        switch direction {
        case .up:   element.swipeUp(velocity: .fast)
        case .down: element.swipeDown(velocity: .fast)
        }
    }

    // MARK: - Tests

    /// Shorts player appears on launch and shows "1 / 3".
    func testShortsPlayerAppears() {
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 5), "Index label should be visible on launch")
        XCTAssertEqual(indexLabel.label, "1 / 3", "Should start at the first short")
    }

    /// Swipe up advances from short 1 → 2.
    func testSwipeUpAdvancesToNextShort() {
        let player = openControls()
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 3))
        XCTAssertEqual(indexLabel.label, "1 / 3")

        swipe(.up, on: player)

        XCTAssertTrue(indexLabel.waitForExistence(timeout: 3))
        XCTAssertEqual(indexLabel.label, "2 / 3", "Swipe up should advance to the next short")
    }

    /// Swipe up twice reaches the last short (3 / 3).
    func testSwipeUpTwiceReachesLastShort() {
        let player = openControls()
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 3))

        swipe(.up, on: player)
        _ = indexLabel.waitForExistence(timeout: 3)
        swipe(.up, on: player)
        _ = indexLabel.waitForExistence(timeout: 3)

        XCTAssertEqual(indexLabel.label, "3 / 3", "After two swipes up should be on last short")
    }

    /// Swipe down from short 2 goes back to short 1.
    func testSwipeDownGoesToPreviousShort() {
        let player = openControls()

        swipe(.up, on: player)
        _ = indexLabel.waitForExistence(timeout: 3)
        XCTAssertEqual(indexLabel.label, "2 / 3")

        swipe(.down, on: player)
        _ = indexLabel.waitForExistence(timeout: 3)
        XCTAssertEqual(indexLabel.label, "1 / 3", "Swipe down should go back to the previous short")
    }

    /// Swipe up at the last short does not overflow past "3 / 3".
    func testSwipeUpAtLastShortDoesNotOverflow() {
        let player = openControls()

        swipe(.up, on: player); _ = indexLabel.waitForExistence(timeout: 3)
        swipe(.up, on: player); _ = indexLabel.waitForExistence(timeout: 3)
        XCTAssertEqual(indexLabel.label, "3 / 3")

        swipe(.up, on: player)
        _ = indexLabel.waitForExistence(timeout: 2)

        XCTAssertEqual(indexLabel.label, "3 / 3", "Swipe up at the last short should stay on '3 / 3'")
    }

    /// Swipe down at the first short does not underflow below "1 / 3".
    func testSwipeDownAtFirstShortDoesNotUnderflow() {
        let player = openControls()
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 3))
        XCTAssertEqual(indexLabel.label, "1 / 3")

        swipe(.down, on: player)
        _ = indexLabel.waitForExistence(timeout: 2)

        XCTAssertEqual(indexLabel.label, "1 / 3", "Swipe down at the first short should stay on '1 / 3'")
    }

    /// Full round-trip: advance to last short then swipe back to first.
    func testSwipeUpThenDownRoundTrip() {
        let player = openControls()

        swipe(.up, on: player);   _ = indexLabel.waitForExistence(timeout: 3)
        swipe(.up, on: player);   _ = indexLabel.waitForExistence(timeout: 3)
        XCTAssertEqual(indexLabel.label, "3 / 3", "Should reach the last short")

        swipe(.down, on: player); _ = indexLabel.waitForExistence(timeout: 3)
        swipe(.down, on: player); _ = indexLabel.waitForExistence(timeout: 3)
        XCTAssertEqual(indexLabel.label, "1 / 3", "Should return to the first short")
    }
}
