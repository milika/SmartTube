import SwiftUI

/// App entry point – supports iOS 17+, iPadOS 17+, macOS 14+.
struct SmartTubeApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var browseViewModel = BrowseViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(browseViewModel)
                .onChange(of: authService.accessToken) { _, newToken in
                    Task { await browseViewModel.updateAuthToken(newToken) }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
    }
}
