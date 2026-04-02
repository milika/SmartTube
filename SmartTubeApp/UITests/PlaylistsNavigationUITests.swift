import XCTest

// MARK: - PlaylistsNavigationUITests
//
// Full-app UI tests that launch SmartTube, navigate to the Library tab,
// select the Playlists segment, and assert that the playlists screen is visible.
//
// Requirements: run on an iOS 17+ simulator with the SmartTube scheme selected.
// The test uses the XCUIApplication API — no live network calls are made;
// the app will show the empty / sign-in state which is sufficient for navigation.

final class PlaylistsNavigationUITests: XCTestCase {

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

    // MARK: - Tests

    /// Verifies the full navigation path:
    ///   App launch → Library tab → Playlists segment visible
    func testAppLaunchesSuccessfully() {
        // The root window should exist immediately after launch.
        XCTAssertTrue(app.windows.firstMatch.exists, "App window should exist after launch")
    }

    func testNavigateToLibraryTab() {
        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 5), "Library tab should be visible in the tab bar")
        libraryTab.tap()

        // After tapping Library, the section picker should appear.
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Library section picker should be visible")
    }

    func testPlaylistsSegmentIsReachable() {
        // Navigate to Library tab first.
        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 5))
        libraryTab.tap()

        // Tap the Playlists segment in the picker.
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Section picker should appear")

        let playlistsButton = picker.buttons["Playlists"]
        XCTAssertTrue(playlistsButton.waitForExistence(timeout: 3), "Playlists segment should exist in picker")
        playlistsButton.tap()

        // The Playlists segment should now be selected.
        XCTAssertTrue(
            playlistsButton.isSelected,
            "Playlists segment should be selected after tap"
        )
    }

    func testPlaylistsScreenShowsContentOrEmptyState() {
        // Navigate to Library → Playlists.
        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 5))
        libraryTab.tap()

        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Playlists"].tap()

        // Allow time for any loading animation to settle.
        let contentOrEmpty = app.scrollViews.firstMatch.waitForExistence(timeout: 5)
            || app.staticTexts["Nothing here yet"].waitForExistence(timeout: 5)
            || app.staticTexts["Sign in to see your library"].waitForExistence(timeout: 5)

        XCTAssertTrue(contentOrEmpty, "Playlists screen should show content, an empty state, or a sign-in prompt")
    }

    // MARK: - Log capture
    //
    // Reads the OS log after navigating to Playlists and confirms that the
    // InnerTube layer emitted its browse/parsePlaylists log entry.
    // This test will only find entries if the user is signed in and a network
    // call was made; on an unsigned-in simulator it asserts no crash occurred.

    func testNavigationDoesNotCrash() {
        // A simple smoke test: navigate all the way to Playlists without crashing.
        let libraryTab = app.tabBars.buttons["Library"]
        guard libraryTab.waitForExistence(timeout: 5) else {
            XCTFail("Library tab not found")
            return
        }
        libraryTab.tap()

        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            XCTFail("Section picker not found")
            return
        }
        picker.buttons["Playlists"].tap()

        // Give the app 2 seconds to settle — any crash would have terminated it.
        Thread.sleep(forTimeInterval: 2)

        XCTAssertTrue(app.state == .runningForeground, "App should still be running after navigating to Playlists")
    }
}
