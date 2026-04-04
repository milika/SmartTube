import XCTest

// MARK: - CategoryChipHTTP400UITests
//
// End-to-end UI tests that open every category chip in the Home chip bar and
// assert that no HTTP error alert is presented by the BrowseView for any of
// them.  BrowseViewModel surfaces non-auth network errors (including HTTP 400)
// by setting vm.error, which BrowseView materialises as an alert titled "Error".
// Asserting the alert does NOT appear is therefore equivalent to asserting that
// no HTTP 4xx/5xx error was returned for that chip's feed request.
//
// Requirements:
//   • The simulator must have network access so InnerTube requests are made.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.

final class CategoryChipHTTP400UITests: XCTestCase {

    private var app: XCUIApplication!

    // All known chip labels in display order, derived from BrowseSection.allSections.
    // "Home" is always first; the test skips it (already loaded on launch).
    private static let allChipNames: [String] = [
        "Home",
        "Subscriptions",
        "History",
        "Playlists",
        "Channels",
        "Shorts",
        "Music",
        "Gaming",
        "News",
        "Live",
        "Sports",
    ]

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tests

    /// Taps each visible category chip and asserts that the "Error" alert
    /// presented by BrowseView on any HTTP error does NOT appear.
    func testNoCategoryChipTriggersHTTP400() {
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5), "Home tab must be visible")
        homeTab.tap()

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 10), "Chip bar must appear on Home tab")

        var testedChips: [String] = []

        for (index, chipName) in Self.allChipNames.dropFirst().enumerated() {
            guard tapChip(named: chipName, in: chipBar, chipIndex: index) else {
                // Chip not enabled in current settings — skip silently.
                continue
            }

            // Wait up to 15 s for feed to settle (video cards, empty state, or error alert).
            waitForFeedToSettle()

            // BrowseViewModel sets vm.error for any non-auth network failure
            // (HTTP 400 included); BrowseView renders that as an alert titled "Error".
            let errorAlert = app.alerts["Error"]
            XCTAssertFalse(
                errorAlert.exists,
                "An 'Error' alert appeared after tapping the '\(chipName)' chip — " +
                "this indicates an HTTP error was returned for that category's feed request."
            )
            // Dismiss if present so remaining chips can still run.
            if errorAlert.exists {
                errorAlert.buttons.firstMatch.tap()
            }

            testedChips.append(chipName)
        }

        XCTAssertFalse(testedChips.isEmpty, "At least one chip besides 'Home' must have been tested")
    }

    // MARK: - Chip interaction helpers

    /// Resets the chip bar to its leading edge, scrolls proportionally to
    /// bring the `chipIndex`-th chip into view, then taps it.
    ///
    /// Scrolling uses coordinates relative to `chipBar` so the gestures always
    /// land on the correct element regardless of its vertical position on screen.
    /// Returns `false` if the chip button doesn't exist in the current settings.
    @discardableResult
    private func tapChip(named name: String, in chipBar: XCUIElement, chipIndex: Int) -> Bool {
        let chip = chipBar.buttons[name]
        guard chip.waitForExistence(timeout: 3) else { return false }

        // Coordinates relative to chipBar (not the whole app).
        let near  = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let far   = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))

        // 3 right-swipes to reach the leading edge.
        for _ in 0..<3 { near.press(forDuration: 0.05, thenDragTo: far) }

        // Left-swipes to reveal the target chip (~2 chips revealed per swipe).
        let scrollCount = chipIndex / 2
        for _ in 0..<scrollCount { far.press(forDuration: 0.05, thenDragTo: near) }

        guard chip.exists else { return false }
        chip.tap()
        return true
    }

    /// Waits a fixed interval for the InnerTube request to complete.
    /// A fixed sleep avoids XCTest snapshot timeouts that occur when querying
    /// the accessibility tree during an active view-hierarchy transition.
    private func waitForFeedToSettle() {
        Thread.sleep(forTimeInterval: 5)
    }
}

