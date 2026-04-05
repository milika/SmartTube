import SwiftUI
import SmartTubeIOSCore

// MARK: - PlaylistView
//
// Shows the videos inside a user playlist.
// Mirrors the Android `PlaylistFragment`.

public struct PlaylistView: View {
    public let playlistId: String
    public let playlistTitle: String

    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @State private var vm = PlaylistViewModel()
    @State private var selectedVideo: Video?
    @State private var channelDestination: ChannelDestination?
    /// ID of the tapped video; used to restore scroll position after back navigation.
    @State private var scrollIDSaved: String?

    public init(playlistId: String, playlistTitle: String) {
        self.playlistId = playlistId
        self.playlistTitle = playlistTitle
    }

    public var body: some View {
        Group {
            if vm.isLoading && vm.videos.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.videos.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(playlistTitle)
        .onAppear {
            Task {
                await vm.setAuthToken(auth.accessToken)
                vm.load(playlistId: playlistId)
            }
        }
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video)
        }
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .alert("Error", isPresented: .constant(vm.error != nil), presenting: vm.error) { _ in
            Button("Retry") { vm.load(playlistId: playlistId) }
            Button("Dismiss", role: .cancel) { vm.error = nil }
        } message: { err in
            Text(err.localizedDescription)
        }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.settings.compactThumbnails {
                    VStack(spacing: 0) {
                        ForEach(vm.videos) { video in
                            VideoCardView(video: video, compact: true)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .id(video.id)
                                .onTapGesture {
                                    scrollIDSaved = video.id
                                    selectedVideo = video
                                }
                            Divider().padding(.horizontal)
                        }
                        if vm.isLoading {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                } else {
                    LazyVGrid(columns: videoGridColumns, spacing: 12) {
                        ForEach(vm.videos) { video in
                            VideoCardView(video: video, compact: false)
                                .id(video.id)
                                .onTapGesture {
                                    scrollIDSaved = video.id
                                    selectedVideo = video
                                }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    if vm.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
            }
            .onChange(of: selectedVideo) { old, new in
                if old != nil && new == nil, let saved = scrollIDSaved {
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        proxy.scrollTo(saved, anchor: .top)
                    }
                }
            }
            .refreshable { vm.load(playlistId: playlistId, refresh: true) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.stackLayers)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No videos in this playlist")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
