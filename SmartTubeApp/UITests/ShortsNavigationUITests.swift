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

    /// Scrolls the horizontal chip bar left until the Shorts chip is hittable.
    private func scrollToShortsChip() {
        let chipBar = app.scrollViews["home.chipBar"]
        guard chipBar.waitForExistence(timeout: 5) else { return }
        let shortsChip = app.buttons["Shorts"]
        var attempts = 0
        while !shortsChip.isHittable && attempts < 5 {
            chipBar.swipeLeft()
            attempts += 1
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
