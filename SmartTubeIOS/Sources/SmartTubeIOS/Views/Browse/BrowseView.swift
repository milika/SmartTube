import SwiftUI
import SmartTubeIOSCore

// MARK: - BrowseView
//
// Main home feed.  Mirrors the Android `BrowseFragment`.

public struct BrowseView: View {
    @Environment(BrowseViewModel.self) private var vm
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var settings
    @State private var selectedVideo: Video?
    @State private var shortsPresentation: ShortsPresentation?
    @State private var channelDestination: ChannelDestination?
    @State private var showSignIn = false
    @State private var showError = false

    public init() {}

    public var body: some View {
        Group {
            if vm.isLoading && vm.videoGroups.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.videoGroups.isEmpty && !vm.isLoading {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(vm.currentSection.title)
        .toolbar { sectionPicker }
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
        .alert("Error", isPresented: $showError, presenting: vm.error) { _ in
            Button("Retry") { vm.loadContent(refresh: true) }
            Button("Dismiss", role: .cancel) { vm.error = nil }
        } message: { err in
            Text(err.localizedDescription)
        }
        .onChange(of: vm.error == nil ? 0 : 1) { _, hasError in
            if hasError == 1 { showError = true }
        }
        .fullScreenCover(item: $shortsPresentation) { target in
            ShortsPlayerView(videos: target.videos, startIndex: target.startIndex)
        }
        .sheet(isPresented: $showSignIn) { SignInView() }
        .onAppear {
            if vm.videoGroups.isEmpty { vm.loadContent() }
        }
        .refreshable { vm.loadContent(refresh: true) }
    }

    // MARK: - Subviews

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if vm.isAuthRequired && !auth.isSignedIn {
                    guestBanner
                }
                ForEach(vm.videoGroups) { group in
                    if let title = group.title, !title.isEmpty {
                        Text(title)
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                    }
                    if group.layout == .row {
                        VideoRowSection(videos: group.videos, onSelect: { selectVideo($0, from: group.videos) })
                    } else if settings.settings.compactThumbnails {
                        ForEach(group.videos) { video in
                            VideoCardView(video: video, compact: true)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .accessibilityIdentifier("video.card.\(video.id)")
                                .onTapGesture { selectVideo(video, from: group.videos) }
                                .onAppear {
                                    if video.id == group.videos.last?.id {
                                        vm.loadMoreIfNeeded(lastVideo: video)
                                    }
                                }
                            Divider().padding(.horizontal)
                        }
                    } else {
                        // Grid mode: pairs as HStack rows so each row is a truly lazy LazyVStack item
                        ForEach(Array(stride(from: 0, to: group.videos.count, by: 2)), id: \.self) { idx in
                            HStack(alignment: .top, spacing: 12) {
                                let v1 = group.videos[idx]
                                VideoCardView(video: v1, compact: false)
                                    .frame(maxWidth: .infinity)
                                    .accessibilityIdentifier("video.card.\(v1.id)")
                                    .onTapGesture { selectVideo(v1, from: group.videos) }
                                if idx + 1 < group.videos.count {
                                    let v2 = group.videos[idx + 1]
                                    VideoCardView(video: v2, compact: false)
                                        .frame(maxWidth: .infinity)
                                        .accessibilityIdentifier("video.card.\(v2.id)")
                                        .onTapGesture { selectVideo(v2, from: group.videos) }
                                } else {
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .onAppear {
                                if idx + 2 >= group.videos.count, let last = group.videos.last {
                                    vm.loadMoreIfNeeded(lastVideo: last)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
        }
    }

    // MARK: - Video selection

    private func selectVideo(_ video: Video, from groupVideos: [Video]) {
        if video.isShort {
            let shorts = groupVideos.filter { $0.isShort }
            let idx = shorts.firstIndex(where: { $0.id == video.id }) ?? 0
            shortsPresentation = ShortsPresentation(videos: shorts, startIndex: idx)
        } else {
            selectedVideo = video
        }
    }

    private var guestBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: AppSymbol.personCircle)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in for your personal feed")
                    .font(.subheadline.weight(.semibold))
                Text("Showing popular videos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign In") { showSignIn = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: vm.isAuthRequired ? AppSymbol.personCircleWarning : AppSymbol.tvPlay)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            if vm.isAuthRequired && !auth.isSignedIn {
                Text("Sign in to see your feed")
                    .font(.title3)
                Text("Your home feed, subscriptions and history\nrequire a Google account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sign In") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Nothing here yet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Refresh") { vm.loadContent(refresh: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var sectionPicker: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Section", selection: Binding(
                get: { vm.currentSection },
                set: { vm.select(section: $0) }
            )) {
                ForEach(vm.sections) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

// MARK: - VideoGridSection

struct VideoGridSection: View {
    let videos: [Video]
    let onSelect: (Video) -> Void
    var loadMore: (() -> Void)? = nil

    @Environment(SettingsStore.self) private var store

    var body: some View {
        let compact = store.settings.compactThumbnails
        if compact {
            LazyVStack(spacing: 0) {
                ForEach(videos) { video in
                    VideoCardView(video: video, compact: true)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onTapGesture { onSelect(video) }
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                    Divider().padding(.horizontal)
                }
            }
        } else {
            LazyVGrid(columns: videoGridColumns, spacing: 12) {
                ForEach(videos) { video in
                    VideoCardView(video: video, compact: false)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onTapGesture { onSelect(video) }
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - VideoRowSection

/// Horizontal scrolling shelf row — used for home feed shelves (layout == .row).
struct VideoRowSection: View {
    let videos: [Video]
    let onSelect: (Video) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(videos) { video in
                    VideoCardView(video: video, compact: false)
                        .frame(width: 220)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onTapGesture { onSelect(video) }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }
}
