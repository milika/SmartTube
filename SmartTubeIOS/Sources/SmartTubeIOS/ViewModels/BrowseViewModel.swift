import Foundation
import Combine
import os
import SmartTubeIOSCore

private let browseLog = Logger(subsystem: "com.smarttube.app", category: "Browse")

// MARK: - BrowseViewModel
//
// Drives the main browse screen.  Mirrors the Android `BrowsePresenter`.

@MainActor
public final class BrowseViewModel: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var sections: [BrowseSection] = BrowseSection.defaultSections
    @Published public private(set) var currentSection: BrowseSection = BrowseSection.defaultSections[0]
    @Published public private(set) var videoGroups: [VideoGroup] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public var error: Error?
    /// True when the current section requires authentication and the user is not signed in.
    @Published public private(set) var isAuthRequired: Bool = false

    // MARK: - Dependencies

    private let api: InnerTubeAPI
    private var fetchTask: Task<Void, Never>?

    public init(api: InnerTubeAPI = InnerTubeAPI(), initialSection: BrowseSection? = nil) {
        self.api = api
        if let initial = initialSection {
            // Ensure the initial section appears in the picker list.
            if !sections.contains(initial) {
                sections = [initial] + sections
            }
            currentSection = initial
        }
    }

    // MARK: - Section selection

    public func select(section: BrowseSection) {
        guard section != currentSection else { return }
        currentSection = section
        loadContent(for: section, refresh: true)
    }

    /// Rebuilds the visible sections list from settings.
    /// Call this when AppSettings.enabledSections changes.
    public func configureSections(_ enabledTypes: [BrowseSection.SectionType]) {
        let allSections = BrowseSection.allSections
        let ordered = enabledTypes.compactMap { type in allSections.first { $0.type == type } }
        sections = ordered.isEmpty ? BrowseSection.defaultSections : ordered
        // If current section is no longer in the list, switch to first
        if !sections.contains(currentSection), let first = sections.first {
            currentSection = first
        }
    }

    // MARK: - Loading

    public func loadContent(for section: BrowseSection? = nil, refresh: Bool = false) {
        let target = section ?? currentSection
        if refresh { videoGroups = [] }
        fetchTask?.cancel()
        fetchTask = Task { await fetchSection(target) }
    }

    public func loadMoreIfNeeded(lastVideo: Video) {
        guard let lastGroup = videoGroups.last,
              let lastInGroup = lastGroup.videos.last,
              lastInGroup.id == lastVideo.id,
              lastGroup.nextPageToken != nil,
              !isLoading
        else { return }
        fetchTask = Task { await fetchNextPage(for: currentSection) }
    }

    // MARK: - Auth

    /// Forward the current access token to the API layer.
    /// Called whenever the user signs in, signs out, or the token is refreshed.
    public func updateAuthToken(_ token: String?) async {
        let msg = token != nil ? "token set (\(token!.prefix(8))…)" : "cleared"
        browseLog.notice("updateAuthToken: \(msg, privacy: .public)")
        print("[Browse] updateAuthToken: \(msg)")
        await api.setAuthToken(token)
        if token != nil {
            loadContent(refresh: true)
        }
    }

    /// Update the API auth token without triggering a content reload.
    public func setAuthToken(_ token: String?) async {
        await api.setAuthToken(token)
    }

    // MARK: - Private fetching

    private func fetchSection(_ section: BrowseSection) async {
        isLoading = true
        defer { isLoading = false }
        browseLog.notice("Fetching section: \(section.title, privacy: .public) (\(String(describing: section.type), privacy: .public))")
        do {
            switch section.type {

            case .home:
                let rows = try await api.fetchHomeRows()
                if !Task.isCancelled {
                    if rows.flatMap({ $0.videos }).isEmpty {
                        isAuthRequired = true
                        let popular = try await api.search(query: "popular")
                        videoGroups = [popular]
                    } else {
                        isAuthRequired = false
                        videoGroups = rows
                    }
                }

            case .trending:
                // YouTube deprecated FEtrending — show empty state instead of propagating error
                videoGroups = []

            case .subscriptions:
                let group = try await api.fetchSubscriptions()
                if !Task.isCancelled {
                    isAuthRequired = group.videos.isEmpty
                    videoGroups = group.videos.isEmpty ? [] : [group]
                }

            case .history:
                let group = try await api.fetchHistory()
                if !Task.isCancelled {
                    isAuthRequired = group.videos.isEmpty
                    videoGroups = group.videos.isEmpty ? [] : [group]
                }

            case .playlists:
                let playlists = try await api.fetchUserPlaylists()
                if !Task.isCancelled {
                    isAuthRequired = playlists.isEmpty
                    // Convert PlaylistInfo list into a VideoGroup of placeholder videos
                    let videos = playlists.map { pl -> Video in
                        Video(id: pl.id, title: pl.title, channelTitle: pl.videoCount.map { "\($0) videos" } ?? "",
                              thumbnailURL: pl.thumbnailURL, playlistId: pl.id)
                    }
                    videoGroups = videos.isEmpty ? [] : [VideoGroup(title: "Playlists", videos: videos)]
                }

            case .channels:
                // Channels section falls through to subscriptions feed;
                // a dedicated channel-list endpoint requires deeper API work.
                let group = try await api.fetchSubscriptions()
                if !Task.isCancelled {
                    isAuthRequired = group.videos.isEmpty
                    videoGroups = group.videos.isEmpty ? [] : [group]
                }

            case .shorts:
                let group = try await api.fetchShorts()
                if !Task.isCancelled { videoGroups = [group] }

            case .music:
                let group = try await api.fetchMusic()
                if !Task.isCancelled { videoGroups = [group] }

            case .gaming:
                let group = try await api.fetchGaming()
                if !Task.isCancelled { videoGroups = [group] }

            case .news:
                let group = try await api.fetchNews()
                if !Task.isCancelled { videoGroups = [group] }

            case .live:
                let group = try await api.fetchLive()
                if !Task.isCancelled { videoGroups = [group] }

            case .sports:
                let group = try await api.fetchSports()
                if !Task.isCancelled { videoGroups = [group] }

            case .settings:
                break
            }
        } catch {
            if !Task.isCancelled {
                // HTTP 401/403 on an auth-gated section means the user is not signed in
                // rather than a real error — surface it as a sign-in prompt.
                let authSections: Set<BrowseSection.SectionType> = [.subscriptions, .history, .playlists]
                if let apiErr = error as? APIError,
                   case .httpError(let code) = apiErr,
                   (code == 401 || code == 403),
                   authSections.contains(section.type) {
                    isAuthRequired = true
                    browseLog.notice("Auth required for \(section.title, privacy: .public) (HTTP \(code, privacy: .public))")
                } else {
                    isAuthRequired = false
                    browseLog.error("❌ \(section.title, privacy: .public) error: \(String(describing: error), privacy: .public)")
                    self.error = error
                }
            }
        }
    }

    private func fetchNextPage(for section: BrowseSection) async {
        guard let token = videoGroups.last?.nextPageToken else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            switch section.type {
            case .home:
                let newRows = try await api.fetchHomeRows(continuationToken: token)
                if !Task.isCancelled { videoGroups.append(contentsOf: newRows) }
            case .subscriptions:
                let group = try await api.fetchSubscriptions(continuationToken: token)
                if !Task.isCancelled { videoGroups.append(group) }
            case .history:
                let group = try await api.fetchHistory(continuationToken: token)
                if !Task.isCancelled { videoGroups.append(group) }
            default:
                break
            }
        } catch {
            if !Task.isCancelled { self.error = error }
        }
    }
}
