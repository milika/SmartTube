import SwiftUI

/// App entry point – supports iOS 17+, iPadOS 17+, macOS 14+.
struct SmartTubeApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var browseViewModel = BrowseViewModel()
    @StateObject private var settingsStore = SettingsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(browseViewModel)
                .environmentObject(settingsStore)
                .onChange(of: authService.accessToken) { _, newToken in
                    Task { await browseViewModel.updateAuthToken(newToken) }
                }
                .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                    browseViewModel.configureSections(newSections)
                }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
    }
}
