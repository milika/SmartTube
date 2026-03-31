import SwiftUI
import SmartTubeIOS

/// Unified entry point for iOS, iPadOS and macOS.
@main
struct AppEntry: App {
    @StateObject private var authService     = AuthService()
    @StateObject private var browseViewModel = BrowseViewModel()
    @StateObject private var settingsStore   = SettingsStore()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(browseViewModel)
                .environmentObject(settingsStore)
                .onChange(of: authService.accessToken, initial: true) { _, newToken in
                    Task { await browseViewModel.updateAuthToken(newToken) }
                }
                .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                    browseViewModel.configureSections(newSections)
                }
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView()
                .environmentObject(authService)
                .environmentObject(browseViewModel)
                .environmentObject(settingsStore)
                .frame(minWidth: 480)
        }
        #else
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(browseViewModel)
                .environmentObject(settingsStore)
                .onChange(of: authService.accessToken, initial: true) { _, newToken in
                    Task { await browseViewModel.updateAuthToken(newToken) }
                }
                .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                    browseViewModel.configureSections(newSections)
                }
        }
        #endif
    }
}
