import SwiftUI
import AuthenticationServices
import SmartTubeIOSCore

// MARK: - SettingsView
//
// App preferences.  Mirrors the Android settings presenters
// (PlayerData, MainUIData, SponsorBlockData, DeArrowData, AccountsData).

public struct SettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var store: SettingsStore
    @State private var showSignIn = false

    public init() {}

    public var body: some View {
        Form {
            accountSection
            playerSection
            uiSection
            sponsorBlockSection
            deArrowSection
            aboutSection
        }
        .navigationTitle("Settings")
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            if auth.isSignedIn {
                HStack {
                    AsyncImage(url: auth.accountAvatarURL) { img in img.resizable().scaledToFill() }
                        placeholder: { Circle().fill(Color.secondary.opacity(0.3)) }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                    Text(auth.accountName ?? "Unknown")
                }
                Button("Sign Out", role: .destructive) { auth.signOut() }
            } else {
                Button("Sign in with Google") { showSignIn = true }
                    .sheet(isPresented: $showSignIn) { SignInView() }
            }
        }
    }

    // MARK: - Player

    private var playerSection: some View {
        Section("Player") {
            Picker("Preferred Quality", selection: $store.settings.preferredQuality) {
                ForEach(AppSettings.VideoQuality.allCases, id: \.self) { q in
                    Text(q.rawValue).tag(q)
                }
            }

            HStack {
                Text("Playback Speed")
                Spacer()
                Picker("", selection: $store.settings.playbackSpeed) {
                    ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { s in
                        Text(s == 1.0 ? "Normal" : "\(s, specifier: "%.2g")×").tag(s)
                    }
                }
                .pickerStyle(.menu)
            }

            Stepper(
                "Seek Back: \(store.settings.seekBackSeconds)s",
                value: $store.settings.seekBackSeconds,
                in: 5...60,
                step: 5
            )
            Stepper(
                "Seek Forward: \(store.settings.seekForwardSeconds)s",
                value: $store.settings.seekForwardSeconds,
                in: 5...60,
                step: 5
            )

            Toggle("Autoplay next video", isOn: $store.settings.autoplayEnabled)
            Toggle("Subtitles", isOn: $store.settings.subtitlesEnabled)
            Toggle("Background Playback", isOn: $store.settings.backgroundPlaybackEnabled)
        }
    }

    // MARK: - UI

    private var uiSection: some View {
        Section("Interface") {
            Picker("Theme", selection: $store.settings.themeName) {
                ForEach(AppSettings.ThemeName.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            Toggle("Hide Shorts", isOn: $store.settings.hideShorts)
            Toggle("Compact Thumbnails", isOn: $store.settings.compactThumbnails)
            NavigationLink("Visible Sections") {
                SectionsSettingsView()
                    .environmentObject(store)
            }
        }
    }

    // MARK: - SponsorBlock

    private var sponsorBlockSection: some View {
        Section {
            Toggle("Enable SponsorBlock", isOn: $store.settings.sponsorBlockEnabled)

            if store.settings.sponsorBlockEnabled {
                ForEach(SponsorSegment.Category.allCases, id: \.self) { cat in
                    Toggle(cat.displayName, isOn: Binding(
                        get: { store.settings.sponsorBlockCategories.contains(cat) },
                        set: { enabled in
                            if enabled {
                                store.settings.sponsorBlockCategories.insert(cat)
                            } else {
                                store.settings.sponsorBlockCategories.remove(cat)
                            }
                        }
                    ))
                }
            }
        } header: {
            Text("SponsorBlock")
        } footer: {
            Text("Automatically skip non-content segments contributed by the community.")
        }
    }

    // MARK: - DeArrow

    private var deArrowSection: some View {
        Section {
            Toggle("Enable DeArrow", isOn: $store.settings.deArrowEnabled)
        } header: {
            Text("DeArrow")
        } footer: {
            Text("Replace clickbait titles and thumbnails with community-sourced alternatives.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
            Button("Reset All Settings", role: .destructive) { store.reset() }
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - SponsorSegment.Category display names

private extension SponsorSegment.Category {
    var displayName: String {
        switch self {
        case .sponsor:       return "Sponsor"
        case .selfPromo:     return "Self-Promotion"
        case .interaction:   return "Interaction Reminder"
        case .intro:         return "Intro/Recap"
        case .outro:         return "Outro/Credits"
        case .preview:       return "Preview/Hook"
        case .filler:        return "Filler Tangent"
        case .musicOfftopic: return "Music (Off-Topic)"
        case .poiHighlight:  return "Highlight (Point of Interest)"
        }
    }
}

// MARK: - SectionsSettingsView

/// Lets the user configure which sections appear in the sidebar / tab bar.
/// Mirrors Android's `MainUIData` section ordering/enabling UI.
struct SectionsSettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    private let allSections = BrowseSection.allSections

    var body: some View {
        List {
            ForEach(allSections) { section in
                Toggle(section.title, isOn: Binding(
                    get: { store.settings.enabledSections.contains(section.type) },
                    set: { enabled in
                        if enabled {
                            if !store.settings.enabledSections.contains(section.type) {
                                // Insert in canonical order
                                let ordered = allSections
                                    .filter { store.settings.enabledSections.contains($0.type) || $0.type == section.type }
                                    .map { $0.type }
                                store.settings.enabledSections = ordered
                            }
                        } else {
                            // Don't allow disabling the last section
                            if store.settings.enabledSections.count > 1 {
                                store.settings.enabledSections.removeAll { $0 == section.type }
                            }
                        }
                    }
                ))
            }
        }
        .navigationTitle("Visible Sections")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
