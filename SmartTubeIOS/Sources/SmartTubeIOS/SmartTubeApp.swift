#if canImport(SwiftUI)
import SwiftUI

/// App entry point – supports iOS 16+, iPadOS 16+, macOS 13+.
@main
struct SmartTubeApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var browseViewModel = BrowseViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(browseViewModel)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
    }
}
#endif
