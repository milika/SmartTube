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
    @State private var vm = PlaylistViewModel()
    @State private var selectedVideo: Video?

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
        .alert("Error", isPresented: .constant(vm.error != nil), presenting: vm.error) { _ in
            Button("Retry") { vm.load(playlistId: playlistId) }
            Button("Dismiss", role: .cancel) { vm.error = nil }
        } message: { err in
            Text(err.localizedDescription)
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.videos) { video in
                    VideoCardView(video: video, compact: true)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .onTapGesture { selectedVideo = video }
                    Divider().padding(.horizontal)
                }
                if vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .refreshable { vm.load(playlistId: playlistId, refresh: true) }
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
