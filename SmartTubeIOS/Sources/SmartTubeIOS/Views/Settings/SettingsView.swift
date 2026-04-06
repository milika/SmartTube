import SwiftUI
import AuthenticationServices
import SmartTubeIOSCore

// MARK: - SettingsView
//
// App preferences.  Mirrors the Android settings presenters
// (PlayerData, MainUIData, SponsorBlockData, DeArrowData, AccountsData).

public struct SettingsView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @State private var showSignIn = false

    public init() {}

    public var body: some View {
        Form {
            accountSection
            playerSection
            uiSection
            youTubeLinkSection
            sponsorBlockSection
            deArrowSection
            aboutSection
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
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
        @Bindable var store = store
        return Section("Player") {
            Picker("Playback Speed", selection: $store.settings.playbackSpeed) {
                ForEach(AppSettings.availableSpeeds, id: \.self) { s in
                    Text(s == 1.0 ? "Normal" : "\(s, specifier: "%.2g")×").tag(s)
                }
            }

            Picker("Max Resolution", selection: $store.settings.preferredQuality) {
                ForEach(AppSettings.VideoQuality.allCases, id: \.self) { q in
                    Text(q == .auto ? "Auto" : q.rawValue).tag(q)
                }
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

            Picker("Hide Controls After", selection: $store.settings.controlsHideTimeout) {
                Text("2s").tag(2)
                Text("3s").tag(3)
                Text("4s").tag(4)
                Text("5s").tag(5)
                Text("8s").tag(8)
                Text("10s").tag(10)
            }

            Picker("Video Fit", selection: $store.settings.videoGravityMode) {
                Text("Fit (letterbox)").tag(AppSettings.VideoGravityMode.fit)
                Text("Fill (crop)").tag(AppSettings.VideoGravityMode.fill)
            }

            Toggle("Loop Video", isOn: $store.settings.loopEnabled)
            Toggle("Shuffle", isOn: $store.settings.shuffleEnabled)

            Toggle("Autoplay next video", isOn: $store.settings.autoplayEnabled)
            Toggle("Subtitles", isOn: $store.settings.subtitlesEnabled)
            Toggle("Background Playback", isOn: $store.settings.backgroundPlaybackEnabled)
        }
    }

    // MARK: - UI

    private var uiSection: some View {
        @Bindable var store = store
        return Section("Interface") {
            Picker("Theme", selection: $store.settings.themeName) {
                ForEach(AppSettings.ThemeName.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            Toggle("Hide Shorts", isOn: $store.settings.hideShorts)
            Toggle("Compact Thumbnails", isOn: $store.settings.compactThumbnails)
            NavigationLink("Visible Sections") {
                SectionsSettingsView()
                    .environment(store)
            }
        }
    }

    // MARK: - YouTube Link Override

    private var youTubeLinkSection: some View {
        @Bindable var store = store
        return Section {
            Toggle("Open YouTube links in SmartTube", isOn: $store.settings.overrideYouTubeLinks)
        } header: {
            Text("YouTube Links")
        } footer: {
            Text("When enabled, SmartTube intercepts youtube:// and vnd.youtube:// deeplinks and opens them in-app. Works when YouTube app is not installed, or when SmartTube is selected via the iOS share sheet.")
        }
    }

    // MARK: - SponsorBlock

    private var sponsorBlockSection: some View {
        @Bindable var store = store
        return Section {
            Toggle("Enable SponsorBlock", isOn: $store.settings.sponsorBlockEnabled)

            if store.settings.sponsorBlockEnabled {
                ForEach(SponsorSegment.Category.allCases, id: \.self) { cat in
                    HStack {
                        Circle()
                            .fill(cat.color)
                            .frame(width: 10, height: 10)
                        Picker(cat.displayName, selection: Binding(
                            get: { store.settings.sponsorBlockActions[cat] ?? .nothing },
                            set: { store.settings.sponsorBlockActions[cat] = $0 }
                        )) {
                            Text("Skip").tag(AppSettings.SponsorBlockAction.skip)
                            Text("Show Toast").tag(AppSettings.SponsorBlockAction.showToast)
                            Text("Nothing").tag(AppSettings.SponsorBlockAction.nothing)
                        }

                    }
                }

                // Minimum segment duration
                Picker("Min. Segment Length", selection: $store.settings.sponsorBlockMinSegmentDuration) {
                    Text("Off").tag(0.0)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                }

                // Excluded channels
                NavigationLink("Excluded Channels (\(store.settings.sponsorBlockExcludedChannels.count))") {
                    SponsorBlockExcludedChannelsView()
                }
            }
        } header: {
            Text("SponsorBlock")
        } footer: {
            Text("Skip \u{2014} auto-skips. Show Toast \u{2014} shows a skip button. Nothing \u{2014} plays through.")
        }
    }

    // MARK: - DeArrow

    private var deArrowSection: some View {
        @Bindable var store = store
        return Section {
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

// MARK: - SectionsSettingsView

/// Lets the user configure which sections appear in the sidebar / tab bar.
/// Mirrors Android's `MainUIData` section ordering/enabling UI.
struct SectionsSettingsView: View {
    @Environment(SettingsStore.self) private var store

    private let allSections = BrowseSection.allSections

    var body: some View {
        @Bindable var store = store
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
        .toolbar(.visible, for: .navigationBar)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - SponsorBlockExcludedChannelsView

/// Lists channels excluded from SponsorBlock processing.
/// Channels can be added from ChannelView and removed here via swipe-to-delete.
struct SponsorBlockExcludedChannelsView: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let sortedChannels = store.settings.sponsorBlockExcludedChannels
            .sorted { $0.value.localizedCompare($1.value) == .orderedAscending }
        return List {
            if sortedChannels.isEmpty {
                ContentUnavailableView(
                    "No Excluded Channels",
                    systemImage: "person.crop.circle.badge.minus",
                    description: Text("Open a channel and tap \u{201C}Exclude from SponsorBlock\u{201D} to add it here.")
                )
            } else {
                ForEach(sortedChannels, id: \.key) { channelId, title in
                    Text(title)
                }
                .onDelete { indices in
                    let ids = indices.map { sortedChannels[$0].key }
                    ids.forEach { store.settings.sponsorBlockExcludedChannels.removeValue(forKey: $0) }
                }
            }
        }
        .navigationTitle("Excluded Channels")
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        #endif
    }
}
