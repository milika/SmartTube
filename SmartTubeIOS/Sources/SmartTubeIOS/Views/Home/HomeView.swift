import SwiftUI
import SmartTubeIOSCore

// MARK: - HomeView
//
// YouTube-style home tab.  A horizontal chip bar at the top lets the user
// switch between every available section:
//   • "Home"  chip  → multi-shelf overview (Subscriptions row,
//                      Recommended row) driven by HomeViewModel.
//   • Any other chip → full-screen video feed for that section driven by a
//                      dedicated BrowseViewModel instance.

public struct HomeView: View {
    @State private var homeVM    = HomeViewModel()
    @State private var sectionVM = BrowseViewModel()
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    // "Home" is always first; its type is .home.
    @State private var selectedSection: BrowseSection = BrowseSection.allSections[0]
    @State private var selectedVideo: Video?
    @State private var shortsPresentation: ShortsPresentation?
    @State private var channelDestination: ChannelDestination?
    @State private var showSignIn = false
    /// ID of the topmost card when the user taps a video; restored via proxy.scrollTo on back-nav.
    @State private var sectionScrollIDSaved: String?

    private var visibleSections: [BrowseSection] {
        let types = store.settings.enabledSections
        guard !types.isEmpty else { return BrowseSection.defaultSections }
        return types.compactMap { type in BrowseSection.allSections.first { $0.type == type } }
    }

    public init() {}

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            chipBar
            Divider()
            contentArea
                .navigationDestination(item: $selectedVideo) { video in
                    PlayerView(video: video)
                }
                .navigationDestination(item: $channelDestination) { dest in
                    ChannelView(channelId: dest.channelId)
                }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .fullScreenCover(item: $shortsPresentation) { target in
            ShortsPlayerView(videos: target.videos, startIndex: target.startIndex)
        }
        .sheet(isPresented: $showSignIn) { SignInView() }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .onChange(of: visibleSections) { _, newSections in
            if !newSections.contains(selectedSection), let first = newSections.first {
                selectedSection = first
            }
        }
        .task(id: auth.accessToken) {
            await homeVM.updateAuthToken(auth.accessToken)
            // Only reload the section feed when it is actually displayed;
            // on the Home chip the feed is hidden so just update the token.
            if selectedSection.type == .home {
                await sectionVM.setAuthToken(auth.accessToken)
            } else {
                await sectionVM.updateAuthToken(auth.accessToken)
            }
        }
    }

    // MARK: - Chip bar

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleSections) { section in
                    chipButton(section: section)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .accessibilityIdentifier("home.chipBar")
    }

    private func chipButton(section: BrowseSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            guard selectedSection != section else { return }
            selectedSection = section
            if section.type != .home {
                sectionVM.select(section: section)
            }
        } label: {
            Text(section.title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    isSelected ? Color.primary : Color.secondary.opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(
                    isSelected
                        ? Color(white: colorScheme == .dark ? 0 : 1)
                        : Color.primary
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selectedSection)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if selectedSection.type == .home {
            homeShelves
        } else {
            sectionFeed
        }
    }

    // MARK: - Home shelves  (multi-section overview)

    private var homeShelves: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(homeVM.sections) { state in
                    if state.isLoading || !state.videos.isEmpty {
                        shelfView(state: state)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .refreshable { homeVM.load() }
    }

    @ViewBuilder
    private func shelfView(state: HomeViewModel.SectionState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.section.title)
                    .font(.title3.bold())
                Spacer()
                if !state.videos.isEmpty && state.section.type != .home {
                    Button("See all") {
                        if let chip = visibleSections.first(where: { $0.id == state.section.id }) {
                            selectedSection = chip
                            sectionVM.select(section: chip)
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)

            if state.isLoading {
                shelfPlaceholder
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(state.videos) { video in
                            VideoCardView(video: video)
                                .frame(width: 240)
                                .accessibilityIdentifier("video.card.\(video.id)")
                                .onTapGesture { selectVideo(video, from: state.videos) }
                                .onAppear {
                                    if state.videos.last?.id == video.id {
                                        homeVM.loadMore(sectionId: state.section.id)
                                    }
                                }
                        }
                        if state.isLoadingMore {
                            ProgressView()
                                .frame(width: 80)
                                .padding(.trailing, 8)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var shelfPlaceholder: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.18))
                            .aspectRatio(16 / 9, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.13))
                            .frame(height: 13)
                            .padding(.horizontal, 4)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.09))
                            .frame(width: 140, height: 11)
                            .padding(.horizontal, 4)
                    }
                    .frame(width: 240)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Section feed  (non-Home chips)

    @ViewBuilder
    private var sectionFeed: some View {
        if sectionVM.isLoading && sectionVM.videoGroups.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sectionVM.videoGroups.isEmpty && !sectionVM.isLoading {
            feedEmptyState
        } else {
            feedContent
        }
    }

    private var feedContent: some View {
        let rowGroups  = sectionVM.videoGroups.filter { $0.layout == .row }
        let gridVideos = sectionVM.videoGroups.filter { $0.layout != .row }.flatMap(\.videos)
        // VStack (not lazy) keeps every item in the view tree so proxy.scrollTo(id)
        // always succeeds, even for items that were off-screen during navigation.
        return ScrollViewReader { proxy in
            ScrollView {
                if store.settings.compactThumbnails {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rowGroups) { group in
                            if let title = group.title, !title.isEmpty {
                                Text(title)
                                    .font(.headline)
                                    .padding(.horizontal)
                                    .padding(.top, 16)
                                    .padding(.bottom, 4)
                            }
                            VideoRowSection(videos: group.videos, onSelect: { selectVideo($0, from: group.videos) })
                        }
                        ForEach(gridVideos) { video in
                            VideoCardView(video: video, compact: true)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .id(video.id)
                                .accessibilityIdentifier("video.card.\(video.id)")
                                .onTapGesture { selectVideo(video, from: gridVideos) }
                                .onAppear {
                                    if video.id == gridVideos.last?.id {
                                        sectionVM.loadMoreIfNeeded(lastVideo: video)
                                    }
                                }
                            Divider().padding(.horizontal)
                        }
                        if sectionVM.isLoading {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rowGroups) { group in
                            if let title = group.title, !title.isEmpty {
                                Text(title)
                                    .font(.headline)
                                    .padding(.horizontal)
                                    .padding(.top, 16)
                                    .padding(.bottom, 4)
                            }
                            VideoRowSection(videos: group.videos, onSelect: { selectVideo($0, from: group.videos) })
                        }
                        ForEach(Array(stride(from: 0, to: gridVideos.count, by: 2)), id: \.self) { idx in
                            HStack(alignment: .top, spacing: 12) {
                                let v1 = gridVideos[idx]
                                VideoCardView(video: v1, compact: false)
                                    .frame(maxWidth: .infinity)
                                    .accessibilityIdentifier("video.card.\(v1.id)")
                                    .onTapGesture { selectVideo(v1, from: gridVideos) }
                                if idx + 1 < gridVideos.count {
                                    let v2 = gridVideos[idx + 1]
                                    VideoCardView(video: v2, compact: false)
                                        .frame(maxWidth: .infinity)
                                        .accessibilityIdentifier("video.card.\(v2.id)")
                                        .onTapGesture { selectVideo(v2, from: gridVideos) }
                                } else {
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                            .id(gridVideos[idx].id)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .onAppear {
                                if idx + 2 >= gridVideos.count, let last = gridVideos.last {
                                    sectionVM.loadMoreIfNeeded(lastVideo: last)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        if sectionVM.isLoading {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                }
            }
            .accessibilityIdentifier("home.sectionFeed")
            .onChange(of: selectedVideo) { old, new in
                if old != nil && new == nil, let saved = sectionScrollIDSaved {
                    // Items are always rendered (VStack, not lazy) so proxy.scrollTo
                    // reliably finds the target even after navigation pop.
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        proxy.scrollTo(saved, anchor: .top)
                    }
                }
            }
            .refreshable { sectionVM.loadContent(refresh: true) }
        }
    }

    private var feedEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: sectionVM.isAuthRequired ? "person.crop.circle.badge.exclamationmark" : "play.tv")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            if sectionVM.isAuthRequired && !auth.isSignedIn {
                Text("Sign in to see this section")
                    .font(.title3)
                Text("Your Google account is required.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sign In") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Nothing here yet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Refresh") { sectionVM.loadContent(refresh: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Video selection

    private func selectVideo(_ video: Video, from groupVideos: [Video]) {
        sectionScrollIDSaved = video.id   // save the tapped video's ID for scroll restoration
        if video.isShort {
            let shorts = groupVideos.filter { $0.isShort }
            let idx = shorts.firstIndex(where: { $0.id == video.id }) ?? 0
            shortsPresentation = ShortsPresentation(videos: shorts, startIndex: idx)
        } else {
            selectedVideo = video
        }
    }
}
