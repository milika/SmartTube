import XCTest

// MARK: - SubscriptionsScrollRestorationUITests
//
// Verifies that the scroll position in the Subscriptions feed is restored after
// opening a video and navigating back.
//
// Flow:
//   1. Navigate to the Subscriptions chip.
//   2. Wait for the feed to load.
//   3. Scroll down until the last visible card is near the bottom of the list
//      (triggering at least one pagination load if needed).
//   4. Record the accessibility identifier of the bottommost visible video card.
//   5. Tap that video to open PlayerView.
//   6. Navigate back via the system back button.
//   7. Assert the previously recorded card is still visible on screen (i.e. the
//      scroll position was not reset to the top).
//
// Requirements:
//   • The simulator must have network access.
//   • A signed-in account is expected so the Subscriptions feed is non-empty.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.

final class SubscriptionsScrollRestorationUITests: XCTestCase {

    private var app: XCUIApplication!

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

    /// Scrolls the Subscriptions feed to load multiple pages, taps the last
    /// visible video, goes back, and asserts the same card is still visible.
    func testScrollPositionRestoredAfterPlayback() throws {
        // 1. Ensure Home tab is active so the chip bar is visible.
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5), "Home tab must be visible")
        homeTab.tap()

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 10), "Chip bar must appear")

        // 2. Tap the Subscriptions chip.
        let chip = chipBar.buttons["Subscriptions"]
        guard chip.waitForExistence(timeout: 5) else {
            throw XCTSkip("Subscriptions chip not found — section may be disabled in settings")
        }
        scrollChipIntoView(chip, in: chipBar)
        chip.tap()

        // 3. Wait for the feed to populate.
        let cardPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(cardPredicate)
        let feedLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"),
            object: cards
        )
        guard XCTWaiter().wait(for: [feedLoaded], timeout: 20) == .completed else {
            throw XCTSkip("Subscriptions feed did not load within 20 s — network unavailable or feed empty")
        }

        // 4. Scroll the section feed down twice to push content below the fold and
        //    trigger at least one pagination load.
        //    We explicitly target the section feed scroll view (not the chip bar).
        let feedScrollView = app.scrollViews["home.sectionFeed"]
        XCTAssertTrue(feedScrollView.waitForExistence(timeout: 5), "home.sectionFeed scroll view must exist")
        feedScrollView.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 3.0)   // let pagination + scrollPosition binding settle
        feedScrollView.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 3.0)

        // 5. Find the bottommost video card that is fully on screen (with a safe margin
        //    from the bottom edge to avoid the home indicator / tab-bar overlap area).
        guard let targetCard = bottommostVisibleCard() else {
            throw XCTSkip("Could not find a fully-visible video card after scrolling")
        }
        let targetID = targetCard.identifier

        // 6. Tap the target card via its centre coordinate — coordinate taps bypass
        //    the hittability check so cards near the edge of the screen still work.
        targetCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // 7. Wait for PlayerView to open.
        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertTrue(titleLabel.waitForExistence(timeout: 15),
                      "player.titleLabel must appear — PlayerView did not open")

        // 8. Navigate back via the always-accessible (but visually invisible) back button
        //    in the player's top-left overlay. This is reliable regardless of whether
        //    the controls overlay is currently shown.
        let backButton = app.buttons["player.backButton"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "player.backButton must be present in PlayerView")
        backButton.tap()

        // 9. Wait for the chip bar to reappear — confirms we're back on the feed.
        XCTAssertTrue(chipBar.waitForExistence(timeout: 5), "Chip bar must reappear after back navigation")

        // 10. Assert: the card we tapped is still visible (not scrolled back to top).
        //     Use firstMatch because the accessibility ID propagates to child image/text elements.
        let restoredCard = app.otherElements
            .matching(NSPredicate(format: "identifier == %@", targetID))
            .firstMatch
        XCTAssertTrue(
            restoredCard.waitForExistence(timeout: 12),
            "Card '\(targetID)' must still exist in the view hierarchy after back navigation"
        )
        // Brief pause to let the UIKit contentOffset commit propagate to the
        // accessibility system before reading element.frame.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(
            isVisibleOnScreen(restoredCard),
            "Card '\(targetID)' must be visible on screen after back navigation — " +
            "scroll position was reset to top instead of being restored"
        )
    }

    // MARK: - Helpers

    /// Returns the video card with the largest `frame.maxY` that is fully within
    /// the visible screen bounds, keeping a 100 pt bottom margin to avoid the
    /// home-indicator / tab-bar area where hit-testing is unreliable.
    ///
    /// Uses per-element iteration (not `allElementsBoundByIndex`) to avoid query
    /// timeouts when all cards are eagerly rendered in a VStack.
    private func bottommostVisibleCard() -> XCUIElement? {
        let screen = app.windows.firstMatch.frame
        let safeMaxY = screen.maxY - 100
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        var bottomCard: XCUIElement? = nil
        var bottomY: CGFloat = -1
        var i = 0
        while i < 200 {  // safety cap
            let card = cards.element(boundBy: i)
            guard card.exists else { break }
            i += 1
            let f = card.frame
            guard f.minX >= 0 && f.minY >= 0
                    && f.maxX <= screen.maxX && f.maxY <= safeMaxY else { continue }
            if f.maxY > bottomY {
                bottomY = f.maxY
                bottomCard = card
            }
        }
        return bottomCard
    }

    /// Returns true when the element's frame is substantially inside the screen.
    private func isVisibleOnScreen(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let screen = app.windows.firstMatch.frame
        let f = element.frame
        // Accept if at least the top half of the card is within the screen.
        return f.minY < screen.maxY && f.midY > screen.minY
            && f.minX < screen.maxX && f.maxX > screen.minX
    }

    /// Scrolls `chip` into the fully-visible area of `chipBar` before tapping.
    private func scrollChipIntoView(_ chip: XCUIElement, in chipBar: XCUIElement) {
        let screenWidth = app.windows.firstMatch.frame.width
        let near = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let far  = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))

        for _ in 0..<8 {
            let frame = chip.frame
            if frame.origin.x >= 4 && frame.maxX <= screenWidth - 4 { break }
            if frame.origin.x < 4 {
                near.press(forDuration: 0.05, thenDragTo: far)
            } else {
                far.press(forDuration: 0.05, thenDragTo: near)
            }
        }
    }
}
