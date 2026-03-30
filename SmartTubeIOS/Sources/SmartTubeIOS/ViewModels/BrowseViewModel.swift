#if canImport(SwiftUI)
import Foundation
import Combine

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

    // MARK: - Private fetching

    private func fetchSection(_ section: BrowseSection) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let group: VideoGroup
            switch section.type {
            case .home:          group = try await api.fetchHome()
            case .trending:      group = try await api.fetchTrending()
            case .subscriptions: group = try await api.fetchSubscriptions()
            case .history:       group = try await api.fetchHistory()
            case .shorts:        group = try await api.fetchHome()   // filtered client-side
            default:             group = try await api.fetchHome()
            }
            if !Task.isCancelled {
                videoGroups = [group]
            }
        } catch {
            if !Task.isCancelled { self.error = error }
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
#endif
