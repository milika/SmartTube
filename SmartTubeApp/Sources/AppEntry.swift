import SwiftUI
import SmartTubeIOS
import SmartTubeIOSCore

/// Unified entry point for iOS, iPadOS and macOS.
@main
struct AppEntry: App {
    @State private var authService     = AuthService()
    @State private var browseViewModel = BrowseViewModel()
    @State private var settingsStore   = SettingsStore()
    @Environment(\.scenePhase) private var scenePhase

    private static let appGroup   = "group.com.void.smarttube"
    private static let pendingKey = "pendingVideoID"

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
                .onChange(of: settingsStore.settings.historyState, initial: true) { _, newState in
                    browseViewModel.updateHistoryEnabled(newState == .enabled)
                }
                .onOpenURL { url in handleOpenURL(url) }
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView()
                .environment(authService)
                .environment(browseViewModel)
                .environment(settingsStore)
                .frame(minWidth: 480)
        }
        #elseif os(tvOS)
        // tvOS: no Share Extension, no Settings scene, no App Group pending video.
        // The device-code + QR sign-in flow works natively on Apple TV.
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
                .onChange(of: settingsStore.settings.historyState, initial: true) { _, newState in
                    browseViewModel.updateHistoryEnabled(newState == .enabled)
                }
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
                    .onChange(of: settingsStore.settings.historyState, initial: true) { _, newState in
                        browseViewModel.updateHistoryEnabled(newState == .enabled)
                    }
                    .onOpenURL { url in handleOpenURL(url) }
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        if phase == .active { consumePendingVideoID() }
                    }
            }
        }
        #endif
    }

    // MARK: - URL handling

    @MainActor
    private func handleOpenURL(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""

        // smarttube://video/VIDEO_ID — fired by the Share Extension
        guard scheme == "smarttube", url.host?.lowercased() == "video" else { return }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let videoID = components.first, !videoID.isEmpty else { return }
        browseViewModel.deepLinkedVideo = Video(id: videoID, title: "", channelTitle: "")
    }

    // MARK: - App Group pending video (from Share Extension)

    @MainActor
    private func consumePendingVideoID() {
        guard let defaults = UserDefaults(suiteName: Self.appGroup),
              let videoID = defaults.string(forKey: Self.pendingKey),
              !videoID.isEmpty
        else { return }

        defaults.removeObject(forKey: Self.pendingKey)
        defaults.synchronize()
        browseViewModel.deepLinkedVideo = Video(id: videoID, title: "", channelTitle: "")
    }

    // MARK: - Stub data for UI testing

    static let stubShorts: [Video] = [
        Video(id: "short-1", title: "Short One",   channelTitle: "Channel A", isShort: true),
        Video(id: "short-2", title: "Short Two",   channelTitle: "Channel B", isShort: true),
        Video(id: "short-3", title: "Short Three", channelTitle: "Channel C", isShort: true),
    ]
}
