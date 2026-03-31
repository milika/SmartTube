import Foundation
import Observation
import SmartTubeIOSCore

// MARK: - SearchViewModel
//
// Mirrors the Android `SearchPresenter`.

@MainActor
@Observable
public final class SearchViewModel {

    public var query: String = ""
    public private(set) var results: [Video] = []
    public private(set) var suggestions: [String] = []
    public private(set) var isLoading: Bool = false
    public var error: Error?

    private let api: InnerTubeAPI
    private var nextPageToken: String?
    private var searchTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?

    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
    }

    /// Call from `.task(id: query)` in the view to debounce live suggestions.
    public func updateSuggestions(for q: String) async {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        if q.isEmpty {
            suggestions = []
        } else {
            fetchSuggestions(for: q)
        }
    }

    public func search() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        results = []
        nextPageToken = nil
        suggestions = []
        searchTask?.cancel()
        searchTask = Task { await performSearch(query: query) }
    }

    public func loadMore() {
        guard let token = nextPageToken, !isLoading else { return }
        searchTask = Task { await performSearch(query: query, continuationToken: token) }
    }

    private func performSearch(query: String, continuationToken: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let group = try await api.search(query: query, continuationToken: continuationToken)
            if continuationToken == nil {
                results = group.videos
            } else {
                results.append(contentsOf: group.videos)
            }
            nextPageToken = group.nextPageToken
        } catch {
            if !Task.isCancelled { self.error = error }
        }
    }

    private func fetchSuggestions(for query: String) {
        suggestTask?.cancel()
        suggestTask = Task {
            let s = try? await api.fetchSearchSuggestions(query: query)
            if !Task.isCancelled { suggestions = s ?? [] }
        }
    }
}

// MARK: - ChannelViewModel

@MainActor
@Observable
public final class ChannelViewModel {

    public private(set) var channel: Channel?
    public private(set) var videos: [Video] = []
    public private(set) var isLoading: Bool = false
    public var error: Error?

    private let api: InnerTubeAPI
    private var nextPageToken: String?

    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
    }

    public func load(channelId: String) {
        Task { await loadAsync(channelId: channelId) }
    }

    private func loadAsync(channelId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (ch, group) = try await api.fetchChannel(channelId: channelId)
            channel = ch
            videos  = group.videos
            nextPageToken = group.nextPageToken
        } catch {
            self.error = error
        }
    }

    public func loadMore() {
        guard let id = channel?.id, let token = nextPageToken, !isLoading else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let group = try await api.fetchChannelVideos(channelId: id, continuationToken: token)
                videos.append(contentsOf: group.videos)
                nextPageToken = group.nextPageToken
            } catch {
                self.error = error
            }
        }
    }
}
