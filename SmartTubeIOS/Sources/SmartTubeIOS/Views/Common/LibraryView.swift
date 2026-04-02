import SwiftUI
import SmartTubeIOSCore

// MARK: - LibraryView
//
// Shows subscriptions, playlists, watch history and liked videos for the
// signed-in account.  Mirrors the Android launcher activities for
// Subscriptions, Playlists, History and Channels.

public struct LibraryView: View {
    @Environment(AuthService.self) private var auth
    @Environment(BrowseViewModel.self) private var browseVM
    @State private var selectedSection: LibrarySection = .subscriptions
    @State private var selectedVideo: Video?
    @State private var selectedPlaylist: Video?

    enum LibrarySection: String, CaseIterable, Identifiable {
        case subscriptions = "Subscriptions"
        case history       = "History"
        case playlists     = "Playlists"

        var id: String { rawValue }
        var browseSectionType: BrowseSection.SectionType {
            switch self {
            case .subscriptions: return .subscriptions
            case .history:       return .history
            case .playlists:     return .playlists
            }
        }
    }

    public init() {}

    public var body: some View {
        Group {
            if auth.isSignedIn {
                authenticatedContent
            } else {
                signedOutPrompt
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video)
        }
        .navigationDestination(item: $selectedPlaylist) { stub in
            PlaylistView(playlistId: stub.id, playlistTitle: stub.title)
        }
    }

    private var authenticatedContent: some View {
        VStack(spacing: 0) {
            Picker("Library Section", selection: $selectedSection) {
                ForEach(LibrarySection.allCases) { sec in
                    Text(sec.rawValue).tag(sec)
                        .accessibilityIdentifier("library.picker.\(sec.rawValue.lowercased())")
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("library.sectionPicker")
            .padding()

            Group {
                let videos = browseVM.videoGroups.flatMap { $0.videos }
                if browseVM.isLoading && videos.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if videos.isEmpty {
                    emptyLibraryView
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(videos) { video in
                                VideoCardView(video: video, compact: true)
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                    .onTapGesture {
                                        if video.playlistId == video.id {
                                            selectedPlaylist = video
                                        } else {
                                            selectedVideo = video
                                        }
                                    }
                                Divider().padding(.horizontal)
                            }
                            if browseVM.isLoading {
                                ProgressView().padding()
                            }
                        }
                    }
                    .refreshable {
                        browseVM.loadContent(
                            for: BrowseSection(
                                id: selectedSection.id,
                                title: selectedSection.rawValue,
                                type: selectedSection.browseSectionType
                            ),
                            refresh: true
                        )
                    }
                }
            }
        }
        .onChange(of: selectedSection) { _, section in
            browseVM.select(section: BrowseSection(
                id: section.id,
                title: section.rawValue,
                type: section.browseSectionType
            ))
        }
        .onAppear {
            browseVM.select(section: BrowseSection(
                id: selectedSection.id,
                title: selectedSection.rawValue,
                type: selectedSection.browseSectionType
            ))
        }
    }

    private var emptyLibraryView: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.stackLayers)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Nothing here yet")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var signedOutPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.personCircleQuestion)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Sign in to see your library")
                .font(.headline)
                .foregroundStyle(.secondary)
            NavigationLink("Sign In") {
                SignInView()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
