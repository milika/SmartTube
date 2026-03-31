import Foundation
import os
import SmartTubeIOSCore

private let homeLog = Logger(subsystem: "com.smarttube.app", category: "Home")

// MARK: - HomeViewModel
//
// Fetches Trending, Subscriptions and Recommended shelves in parallel
// to populate the Home tab's multi-section feed.

@MainActor
public final class HomeViewModel: ObservableObject {

    // MARK: - Section state

    public struct SectionState: Identifiable {
        public let section: BrowseSection
        public var videos: [Video] = []
        public var isLoading: Bool = true
        public var hasFailed: Bool = false
        public var id: String { section.id }
    }

    // MARK: - Published state

    @Published public private(set) var sections: [SectionState]
    @Published public private(set) var isRefreshing: Bool = false

    // MARK: - Shelf definitions (in display order)

    public static let shelfSections: [BrowseSection] = [
        BrowseSection(id: "home",          title: "Recommended",   type: .home),
        BrowseSection(id: "trending",      title: "Trending",      type: .trending),
        BrowseSection(id: "subscriptions", title: "Subscriptions", type: .subscriptions),
    ]

    // MARK: - Dependencies

    private let api: InnerTubeAPI
    private var loadTask: Task<Void, Never>?

    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
        self.sections = Self.shelfSections.map { SectionState(section: $0) }
    }

    // MARK: - Public API

    public func load() {
        loadTask?.cancel()
        isRefreshing = true
        for i in sections.indices {
            sections[i].videos = []
            sections[i].isLoading = true
            sections[i].hasFailed = false
        }
        loadTask = Task {
            await withTaskGroup(of: (String, [Video]).self) { group in
                for state in sections {
                    let sectionId = state.id
                    let type = state.section.type
                    let api = self.api
                    group.addTask {
                        let videos = await HomeViewModel.fetchVideos(type: type, api: api)
                        return (sectionId, videos)
                    }
                }
                for await (sectionId, videos) in group {
                    guard !Task.isCancelled else { break }
                    if let idx = sections.firstIndex(where: { $0.id == sectionId }) {
                        sections[idx].videos = videos
                        sections[idx].isLoading = false
                        sections[idx].hasFailed = videos.isEmpty
                    }
                }
            }
            isRefreshing = false
        }
    }

    public func updateAuthToken(_ token: String?) async {
        await api.setAuthToken(token)
        load()
    }

    /// Non-isolated so child tasks run on the global executor and network
    /// calls can overlap.
    private static func fetchVideos(type: BrowseSection.SectionType, api: InnerTubeAPI) async -> [Video] {
        do {
            switch type {
            case .trending:
                let group = try await api.fetchTrending()
                return Array(group.videos.prefix(20))
            case .subscriptions:
                let group = try await api.fetchSubscriptions()
                return Array(group.videos.prefix(20))
            case .home:
                let rows = try await api.fetchHomeRows()
                return Array(rows.flatMap(\.videos).prefix(20))
            default:
                return []
            }
        } catch {
            homeLog.error("HomeViewModel fetch \(String(describing: type)): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
