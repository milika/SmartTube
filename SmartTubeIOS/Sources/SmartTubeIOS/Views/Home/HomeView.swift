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
    @StateObject private var homeVM    = HomeViewModel()
    @StateObject private var sectionVM = BrowseViewModel()
    @EnvironmentObject private var auth: AuthService
    @Environment(\.colorScheme) private var colorScheme

    // "Home" is always first; its type is .home.
    @State private var selectedSection: BrowseSection = BrowseSection.allSections[0]
    @State private var selectedVideo: Video?
    @State private var showSignIn = false

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
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSignIn) { SignInView() }
        .task(id: auth.accessToken) {
            await homeVM.updateAuthToken(auth.accessToken)
            await sectionVM.updateAuthToken(auth.accessToken)
        }
    }

    // MARK: - Chip bar

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BrowseSection.allSections) { section in
                    chipButton(section: section)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
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
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if selectedSection.id == "home" {
            homeShelves
        } else {
            sectionFeed
        }
    }

    // MARK: - Home shelves  (multi-section overview)

    private var homeShelves: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
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
                if !state.videos.isEmpty {
                    Button("See all") {
                        // Recommended shelf (id "home") deep-links to the "Recommended" chip;
                        // other shelves deep-link to their matching chip by id.
                        let chipId = state.section.id == "home" ? "recommended" : state.section.id
                        if let chip = BrowseSection.allSections.first(where: { $0.id == chipId }) {
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
                    LazyHStack(spacing: 16) {
                        ForEach(state.videos) { video in
                            VideoCardView(video: video)
                                .frame(width: 240)
                                .onTapGesture { selectedVideo = video }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sectionVM.videoGroups) { group in
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
                        VideoGridSection(
                            videos: group.videos,
                            onSelect: { selectedVideo = $0 },
                            loadMore: {
                                if let last = group.videos.last {
                                    sectionVM.loadMoreIfNeeded(lastVideo: last)
                                }
                            }
                        )
                    }
                }
                if sectionVM.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .refreshable { sectionVM.loadContent(refresh: true) }
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
}
