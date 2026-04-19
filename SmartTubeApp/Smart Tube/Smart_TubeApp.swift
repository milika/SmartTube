//
//  Smart_TubeApp.swift
//  Smart Tube
//
//  Created by Milika Delic on 19.04.2026.
//

import SwiftUI
import SmartTubeIOS
import SmartTubeIOSCore

/// tvOS entry point for SmartTube.
/// The device-code + QR sign-in flow is natively designed for Apple TV —
/// the user reads a code on screen and activates on their phone at yt.be/activate.
@main
struct SmartTubeTVApp: App {
    @State private var authService     = AuthService()
    @State private var browseViewModel = BrowseViewModel()
    @State private var settingsStore   = SettingsStore()

    var body: some Scene {
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
    }
}
