import SwiftUI
import SmartTubeIOSCore

// MARK: - BrowseView
//
// Main home feed.  Mirrors the Android `BrowseFragment`.

public struct BrowseView: View {
    @EnvironmentObject private var vm: BrowseViewModel
    @EnvironmentObject private var auth: AuthService
    @State private var selectedVideo: Video?
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
        .alert("Error", isPresented: $showError, presenting: vm.error) { _ in
            Button("Retry") { vm.loadContent(refresh: true) }
            Button("Dismiss", role: .cancel) { vm.error = nil }
        } message: { err in
            Text(err.localizedDescription)
        }
        .onChange(of: vm.error == nil ? 0 : 1) { _, hasError in
            if hasError == 1 { showError = true }
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
                        VideoRowSection(videos: group.videos, onSelect: { selectedVideo = $0 })
                    } else {
                        VideoGridSection(videos: group.videos, onSelect: { selectedVideo = $0 },
                                         loadMore: { if let last = group.videos.last { vm.loadMoreIfNeeded(lastVideo: last) } })
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

    private var guestBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
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
            if vm.currentSection.type == .trending {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("Trending is no longer available")
                    .font(.title3)
                Text("YouTube has removed the Trending feed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: vm.isAuthRequired ? "person.crop.circle.badge.exclamationmark" : "play.tv")
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

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(videos) { video in
                VideoCardView(video: video)
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

// MARK: - VideoRowSection

/// Horizontal scrolling shelf row — used for home feed shelves (layout == .row).
struct VideoRowSection: View {
    let videos: [Video]
    let onSelect: (Video) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(videos) { video in
                    VideoCardView(video: video, compact: false)
                        .frame(width: 220)
                        .onTapGesture { onSelect(video) }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }
}
