import SwiftUI
import SmartTubeIOS

/// Unified entry point for iOS, iPadOS and macOS.
@main
struct AppEntry: App {
    @StateObject private var authService     = AuthService()
    @StateObject private var browseViewModel = BrowseViewModel()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(browseViewModel)
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView()
                .environmentObject(authService)
                .environmentObject(browseViewModel)
                .environmentObject(SettingsStore())
                .frame(minWidth: 480)
        }
        #else
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(browseViewModel)
        }
        #endif
    }
}
