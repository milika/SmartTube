import XCTest

// MARK: - PlayerLiveSwipeUITests
//
// End-to-end UI tests with NO mocks.  The app launches normally, navigates to
// the Home tab, taps the first non-Short video card to open PlayerView, then
// exercises left/right swipe navigation:
//   • Swipe left  → play next related video  (vm.playNext())
//   • Swipe right → play previous video       (vm.playPrevious())
//
// Requirements:
//   • The simulator must have network access so InnerTube can return video
//     suggestions (populating vm.relatedVideos → hasNext = true).
//   • The always-visible `player.titleLabel` overlay on PlayerView is used as
//     the assertion target to confirm a new video loaded.
//   • The tests allow up to 20 s for the Home feed to populate.
//
// Swipes are delivered via coordinate-based press-drag so the UIKit-level
// UIPanGestureRecognizer in `SwipeGestureOverlay` fires correctly.

final class PlayerLiveSwipeUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()   // No bypass arguments — full real navigation
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Navigates to the Home tab (first tab) and waits for it to become active.
    private func openHomeTab() {
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5), "Home tab must be visible")
        homeTab.tap()
    }

    /// Waits up to `timeout` seconds for a non-Short `video.card.*` element to appear.
    /// We intentionally look for ANY card here; the Shorts chip won't be selected so
    /// all cards in the Home shelves are regular videos.
    private func waitForFirstVideoCard(timeout: TimeInterval = 20) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                                     object: cards)
        guard XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed else {
            return nil
        }
        return cards.firstMatch
    }

    /// Always-visible title label on `PlayerView`.
    private var titleLabel: XCUIElement {
        app.staticTexts["player.titleLabel"].firstMatch
    }

    /// Swipe left (advance to next video).
    private func swipeLeft() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Swipe right (go back to previous video).
    private func swipeRight() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    // MARK: - Tests

    /// Verifies the player opens, shows a title, and that swipe-left loads the next
    /// video (title changes), then swipe-right goes back to the original.
    func testPlayerSwipeLeftThenRight() throws {
        openHomeTab()

        guard let card = waitForFirstVideoCard(timeout: 20) else {
            throw XCTSkip("No video cards loaded within 20 s — network unavailable or feed empty")
        }

        card.tap()

        // Wait for the player to show the title label.
        XCTAssertTrue(titleLabel.waitForExistence(timeout: 10),
                      "player.titleLabel should appear after opening a video")
        let initialTitle = titleLabel.label

        // Wait for related videos to load (hasNext becomes true).
        // We poll the "next track" button becoming enabled as the signal.
        let nextButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'forward' OR identifier CONTAINS 'next'")
        ).firstMatch
        // Give up to 10 s for related videos to arrive; swipe regardless.
        _ = nextButton.waitForExistence(timeout: 10)

        // Swipe left → should advance to the next related video.
        swipeLeft()
        sleep(2)   // allow new video load + title update

        let afterSwipeLeft = titleLabel.label
        XCTAssertNotEqual(afterSwipeLeft, initialTitle,
                          "Swipe left should load the next related video (title should change)")

        // Swipe right → should go back to the previous video.
        swipeRight()
        sleep(2)

        let afterSwipeRight = titleLabel.label
        XCTAssertEqual(afterSwipeRight, initialTitle,
                       "Swipe right should return to the original video")
    }

    /// Smoke test: open a video and confirm swiping left does not crash the app.
    func testPlayerSwipeLeftDoesNotCrash() throws {
        openHomeTab()

        guard let card = waitForFirstVideoCard(timeout: 20) else {
            throw XCTSkip("No video cards loaded within 20 s — network unavailable or feed empty")
        }
        card.tap()

        XCTAssertTrue(titleLabel.waitForExistence(timeout: 10),
                      "Player should open and show a title")

        swipeLeft()
        sleep(1)

        // The app window must still be alive — no crash.
        XCTAssertTrue(app.windows.firstMatch.exists,
                      "App should still be running after swipe left in player")
    }

    /// Smoke test: swipe right on the first video (no history) does not crash.
    func testPlayerSwipeRightOnFirstVideoDoesNotCrash() throws {
        openHomeTab()

        guard let card = waitForFirstVideoCard(timeout: 20) else {
            throw XCTSkip("No video cards loaded within 20 s — network unavailable or feed empty")
        }
        card.tap()

        XCTAssertTrue(titleLabel.waitForExistence(timeout: 10),
                      "Player should open and show a title")
        let initialTitle = titleLabel.label

        // Swipe right: no history → should stay on the same video.
        swipeRight()
        sleep(1)

        XCTAssertTrue(app.windows.firstMatch.exists, "App should not crash")
        // Title should be unchanged (no previous video to navigate to).
        XCTAssertEqual(titleLabel.label, initialTitle,
                       "Swipe right when there is no history should not change the video")
    }

    // MARK: - Controls-visible swipe tests
    //
    // Verify that left-/right-swipe navigation still fires when the controls
    // overlay is displayed.  Controls are revealed by tapping the player (which
    // triggers SwipeGestureOverlay.onTap → vm.showControls() → controlsVisible = true).
    // The swipe is performed immediately while the overlay is on screen.

    /// Returns true once `player.nextBtn` exists AND is enabled (hasNext = true),
    /// keeping the controls overlay alive by tapping every 3.5 s.
    /// Controls auto-hide after 4 s, so we re-tap before they disappear.
    private func waitForControlsWithNextEnabled(timeout: TimeInterval = 20) -> Bool {
        let centre = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let nextBtn = app.buttons["player.nextBtn"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            centre.tap()   // show / refresh controls
            if nextBtn.waitForExistence(timeout: 3.5), nextBtn.isEnabled {
                return true
            }
        }
        return false
    }

    /// Swipe left advances to the next video even when the controls overlay is shown.
    func testPlayerSwipeLeftWorksWhenControlsAreVisible() throws {
        openHomeTab()

        guard let card = waitForFirstVideoCard(timeout: 20) else {
            throw XCTSkip("No video cards loaded within 20 s — network unavailable or feed empty")
        }
        card.tap()

        XCTAssertTrue(titleLabel.waitForExistence(timeout: 10),
                      "Player should open and show a title")
        let initialTitle = titleLabel.label

        // Keep tapping to maintain controls visibility while waiting for hasNext.
        guard waitForControlsWithNextEnabled(timeout: 20) else {
            throw XCTSkip("Related videos did not load within 20 s — network unavailable")
        }

        // Controls are visible (last tap was ≤ 3.5 s ago) and hasNext = true.
        // Swipe left while the controls overlay is on screen.
        swipeLeft()
        sleep(2)

        XCTAssertNotEqual(titleLabel.label, initialTitle,
                          "Swipe left should load the next video even when controls are visible")
    }

    /// Swipe right returns to the previous video even when controls are shown.
    func testPlayerSwipeRightWorksWhenControlsAreVisible() throws {
        openHomeTab()

        guard let card = waitForFirstVideoCard(timeout: 20) else {
            throw XCTSkip("No video cards loaded within 20 s — network unavailable or feed empty")
        }
        card.tap()

        XCTAssertTrue(titleLabel.waitForExistence(timeout: 10),
                      "Player should open and show a title")
        let firstTitle = titleLabel.label

        // Wait for related videos (controls not shown, just using time).
        guard waitForControlsWithNextEnabled(timeout: 20) else {
            throw XCTSkip("Related videos did not load within 20 s — network unavailable")
        }
        // Controls are visible and hasNext = true.
        // Advance to video 2 by swiping left while controls are on screen.
        swipeLeft()
        sleep(2)
        let secondTitle = titleLabel.label
        XCTAssertNotEqual(secondTitle, firstTitle, "Must be on a second video before testing controls")

        // Tap to reveal the controls overlay again.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Swipe right while controls are visible — should return to the first video.
        swipeRight()
        sleep(2)

        XCTAssertEqual(titleLabel.label, firstTitle,
                       "Swipe right should return to the previous video even when controls are visible")
    }
}
