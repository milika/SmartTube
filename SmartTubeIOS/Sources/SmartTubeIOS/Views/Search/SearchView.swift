import SwiftUI
import SmartTubeIOSCore

// MARK: - SearchView
//
// Search interface with live suggestions and paginated results.
// Mirrors the Android `SearchTagsActivity`.

public struct SearchView: View {
    @EnvironmentObject private var vm: SearchViewModel
    @State private var selectedVideo: Video?
    @FocusState private var isSearchFocused: Bool

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            Group {
                if vm.results.isEmpty && !vm.isLoading && vm.query.isEmpty {
                    placeholderView
                } else if vm.results.isEmpty && !vm.isLoading && !vm.query.isEmpty {
                    noResultsView
                } else {
                    resultsView
                }
            }
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video)
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search YouTube", text: $vm.query)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { vm.search() }
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Results

    private var resultsView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if vm.isLoading && vm.results.isEmpty {
                    ProgressView().padding()
                }
                ForEach(vm.results) { video in
                    VideoCardView(video: video, compact: true)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .onTapGesture { selectedVideo = video }
                        .onAppear {
                            if video.id == vm.results.last?.id { vm.loadMore() }
                        }
                    Divider().padding(.horizontal)
                }
                if vm.isLoading && !vm.results.isEmpty {
                    ProgressView().padding()
                }
            }
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Search for videos, channels & playlists")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No results for \"\(vm.query)\"")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
