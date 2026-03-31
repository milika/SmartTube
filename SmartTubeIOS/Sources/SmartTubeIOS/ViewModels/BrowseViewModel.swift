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

    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
    }

    // MARK: - Section selection

    public func select(section: BrowseSection) {
        guard section != currentSection else { return }
        currentSection = section
        loadContent(for: section, refresh: true)
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

    // MARK: - Private fetching

    private func fetchSection(_ section: BrowseSection) async {
        isLoading = true
        defer { isLoading = false }
        browseLog.notice("Fetching section: \(section.title, privacy: .public) (\(String(describing: section.type), privacy: .public))")
        do {
            let group: VideoGroup
            switch section.type {
            case .home:
                let homeGroup = try await api.fetchHome()
                if homeGroup.videos.isEmpty {
                    // YouTube gates FEwhat_to_watch behind login — show popular content for guests
                    isAuthRequired = true
                    group = try await api.search(query: "popular")
                } else {
                    isAuthRequired = false
                    group = homeGroup
                }
            case .trending:      group = try await api.search(query: "trending")  // FEtrending is deprecated
            case .subscriptions: group = try await api.fetchSubscriptions()
            case .history:       group = try await api.fetchHistory()
            case .shorts:        group = try await api.fetchHome()   // filtered client-side
            default:             group = try await api.fetchHome()
            }
            if !Task.isCancelled {
                if section.type != .home {   // home already sets isAuthRequired above
                    let authSections: Set<BrowseSection.SectionType> = [.subscriptions, .history]
                    isAuthRequired = group.videos.isEmpty && authSections.contains(section.type)
                }
                browseLog.notice("✅ \(section.title, privacy: .public): \(group.videos.count, privacy: .public) videos, authRequired=\(self.isAuthRequired, privacy: .public)")
                videoGroups = [group]
            }
        } catch {
            if !Task.isCancelled {
                isAuthRequired = false
                browseLog.error("❌ \(section.title, privacy: .public) error: \(String(describing: error), privacy: .public)")
                self.error = error
            }
        }
    }

    private func fetchNextPage(for section: BrowseSection) async {
        guard let token = videoGroups.last?.nextPageToken else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let group: VideoGroup
            switch section.type {
            case .home:          group = try await api.fetchHome(continuationToken: token)
            case .subscriptions: group = try await api.fetchSubscriptions(continuationToken: token)
            case .history:       group = try await api.fetchHistory(continuationToken: token)
            default:             return
            }
            if !Task.isCancelled {
                videoGroups.append(group)
            }
        } catch {
            if !Task.isCancelled { self.error = error }
        }
    }
}
