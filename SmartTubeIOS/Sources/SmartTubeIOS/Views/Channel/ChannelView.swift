#if canImport(SwiftUI)
import SwiftUI

// MARK: - ChannelView
//
// Displays channel info, subscriber count and a grid of recent uploads.
// Mirrors the Android `ChannelFragment`.

public struct ChannelView: View {
    public let channelId: String
    @StateObject private var vm = ChannelViewModel()
    @State private var selectedVideo: Video?

    public init(channelId: String) {
        self.channelId = channelId
    }

    public var body: some View {
        Group {
            if vm.isLoading && vm.channel == nil {
                ProgressView("Loading channel…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .navigationTitle(vm.channel?.title ?? "Channel")
        .onAppear { vm.load(channelId: channelId) }
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video)
        }
        .alert("Error", isPresented: .constant(vm.error != nil), presenting: vm.error) { _ in
            Button("Retry") { vm.load(channelId: channelId) }
            Button("Dismiss", role: .cancel) {}
        } message: { err in
            Text(err.localizedDescription)
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Channel header
                if let channel = vm.channel {
                    channelHeader(channel)
                }

                // Videos
                let columns = [GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vm.videos) { video in
                        VideoCardView(video: video)
                            .onTapGesture { selectedVideo = video }
                            .onAppear {
                                if video.id == vm.videos.last?.id { vm.loadMore() }
                            }
                    }
                }
                .padding()

                if vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .refreshable { vm.load(channelId: channelId) }
    }

    private func channelHeader(_ channel: Channel) -> some View {
        HStack(spacing: 16) {
            AsyncImage(url: channel.thumbnailURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color(.systemGray4))
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                if let subs = channel.subscriberCount {
                    Text(subs)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let desc = channel.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding()
        .background(Color(.systemBackground))
    }
}
#endif
