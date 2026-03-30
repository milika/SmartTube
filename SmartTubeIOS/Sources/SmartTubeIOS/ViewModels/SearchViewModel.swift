#if canImport(SwiftUI)
import Foundation
import Combine

// MARK: - SearchViewModel
//
// Mirrors the Android `SearchPresenter`.

@MainActor
public final class SearchViewModel: ObservableObject {

    @Published public var query: String = ""
    @Published public private(set) var results: [Video] = []
    @Published public private(set) var suggestions: [String] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public var error: Error?

    private let api: InnerTubeAPI
    private var nextPageToken: String?
    private var searchTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
        $query
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] q in
                guard let self else { return }
                if q.isEmpty {
                    self.suggestions = []
                } else {
                    self.fetchSuggestions(for: q)
                }
            }
            .store(in: &cancellables)
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
public final class ChannelViewModel: ObservableObject {

    @Published public private(set) var channel: Channel?
    @Published public private(set) var videos: [Video] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public var error: Error?

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
#endif
