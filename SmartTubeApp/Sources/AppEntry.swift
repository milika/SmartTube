import SwiftUI
import SmartTubeIOS
import SmartTubeIOSCore

/// Unified entry point for iOS, iPadOS and macOS.
@main
struct AppEntry: App {
    @State private var authService     = AuthService()
    @State private var browseViewModel = BrowseViewModel()
    @State private var settingsStore   = SettingsStore()

    /// When launched with `--uitesting-shorts` the app skips the full navigation
    /// stack and presents ShortsPlayerView directly with three stub videos so
    /// XCUITest can exercise swipe-up / swipe-down navigation without a network
    /// call or sign-in state.
    private var isShortsUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting-shorts")
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .environment(authService)
                .environment(browseViewModel)
                .environment(settingsStore)
                .onChange(of: authService.accessToken, initial: true) { _, newToken in
                    Task { await browseViewModel.updateAuthToken(newToken) }
                }
                .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                    browseViewModel.configureSections(newSections)
                }
                .onOpenURL { url in
                    handleOpenURL(url)
                }
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView()
                .environment(authService)
                .environment(browseViewModel)
                .environment(settingsStore)
                .frame(minWidth: 480)
        }
        #else
        WindowGroup {
            if isShortsUITesting {
                ShortsPlayerView(videos: AppEntry.stubShorts, startIndex: 0)
                    .environment(settingsStore)
            } else {
                RootView()
                    .environment(authService)
                    .environment(browseViewModel)
                    .environment(settingsStore)
                    .onChange(of: authService.accessToken, initial: true) { _, newToken in
                        Task { await browseViewModel.updateAuthToken(newToken) }
                    }
                    .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                        browseViewModel.configureSections(newSections)
                    }
                    .onOpenURL { url in
                        handleOpenURL(url)
                    }
            }
        }
        #endif
    }

    // MARK: - URL handling

    @MainActor
    private func handleOpenURL(_ url: URL) {
        // Only intercept when the user has opted in.
        guard settingsStore.settings.overrideYouTubeLinks else { return }
        guard let videoID = YouTubeLinkHandler.videoID(from: url) else { return }
        browseViewModel.deepLinkedVideo = Video(id: videoID, title: "", channelTitle: "")
    }

    // MARK: - Stub data for UI testing

    static let stubShorts: [Video] = [
        Video(id: "short-1", title: "Short One",   channelTitle: "Channel A", isShort: true),
        Video(id: "short-2", title: "Short Two",   channelTitle: "Channel B", isShort: true),
        Video(id: "short-3", title: "Short Three", channelTitle: "Channel C", isShort: true),
    ]
}
