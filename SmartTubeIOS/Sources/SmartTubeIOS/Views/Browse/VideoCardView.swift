import SwiftUI
import SmartTubeIOSCore

// MARK: - Notification names

extension Notification.Name {
    /// Posted when the user selects "Open Channel" from a video's context menu.
    /// userInfo keys: "channelId", "channelTitle"
    static let openChannel = Notification.Name("com.smarttube.openChannel")
}

// MARK: - VideoCardView
//
// A card showing a video thumbnail, title, channel and metadata.
// Adapts its layout for list (compact) and grid (default) modes.

public struct VideoCardView: View {
    public let video: Video
    public var compact: Bool = false

    @Environment(AuthService.self) private var authService
    #if !os(tvOS)
    @State private var downloadService = VideoDownloadService()
    @State private var downloadAlertItem: DownloadAlertItem?
    #endif
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    public init(video: Video, compact: Bool = false) {
        self.video = video
        self.compact = compact
    }

    public var body: some View {
        Group {
            if compact {
                compactLayout
            } else {
                gridLayout
            }
        }
        .contextMenu {
            #if !os(tvOS)
            if let shareURL = URL(string: "https://www.youtube.com/watch?v=\(video.id)") {
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: AppSymbol.share)
                }
            }
            #endif
            if let channelId = video.channelId, !channelId.isEmpty {
                Button {
                    NotificationCenter.default.post(
                        name: .openChannel,
                        object: nil,
                        userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                    )
                } label: {
                    Label("Open Channel", systemImage: AppSymbol.personRectangle)
                }
            }
            #if !os(tvOS)
            Button {
                downloadService.updateAuthToken(authService.accessToken)
                downloadService.download(video: video)
            } label: {
                if downloadService.state.isActive {
                    Label("Downloading…", systemImage: AppSymbol.download)
                } else {
                    Label("Download to Gallery", systemImage: AppSymbol.download)
                }
            }
            .disabled(downloadService.state.isActive)
            #endif
        } preview: {
            Group {
                if compact {
                    compactLayout
                } else {
                    gridLayout
                }
            }
            .padding(12)
            .frame(width: 300)
            .background(.background)
        }
        #if !os(tvOS)
        .onChange(of: downloadService.state) { _, newState in
            switch newState {
            case .done:
                downloadAlertItem = DownloadAlertItem(title: "Saved to Gallery", message: "\"\(video.title)\" has been saved to your Photos library.")
                downloadService.reset()
            case .failed(let reason):
                downloadAlertItem = DownloadAlertItem(title: "Download Failed", message: reason)
                downloadService.reset()
            default:
                break
            }
        }
        .alert(item: $downloadAlertItem) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        #else
        .focused($isFocused)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white, lineWidth: isFocused ? 4 : 0)
        }
        .shadow(color: isFocused ? .white.opacity(0.9) : .clear, radius: 18, x: 0, y: 0)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .zIndex(isFocused ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        #endif
    }

    // MARK: Grid layout (default)

    private var gridLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(thumbnailView.clipped())
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    let dur = video.formattedDuration
                    if !dur.isEmpty { durationBadge(dur) }
                }
                .overlay(alignment: .topLeading) {
                    if video.isLive { liveBadge }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2, reservesSpace: true)
                Text(video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    let vc = video.formattedViewCount
                    if !vc.isEmpty { Text(vc) }
                    if let date = video.publishedAt {
                        Text("· \(date, style: .relative) ago")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Compact (list) layout

    private var compactLayout: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnailView
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    let dur = video.formattedDuration
                    if !dur.isEmpty { durationBadge(dur) }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let vc = video.formattedViewCount
                if !vc.isEmpty {
                    Text(vc)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Shared

    private var thumbnailView: some View {
        // Prefer the explicit thumbnailURL (set for playlist stubs and API-provided thumbs).
        // Fall back to highQualityThumbnailURL only when no explicit URL was provided.
        let url = video.thumbnailURL ?? video.highQualityThumbnailURL
        return AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill()
            case .failure:
                placeholderThumbnail
            default:
                placeholderThumbnail.overlay(ProgressView())
            }
        }
    }

    private var placeholderThumbnail: some View {
        Rectangle().fill(Color.secondary.opacity(0.2))
    }

    private func durationBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.75))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(4)
    }

    private var liveBadge: some View {
        Text("LIVE")
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.red)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(4)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VideoCardView(video: Video(
        id: "dQw4w9WgXcQ",
        title: "Rick Astley – Never Gonna Give You Up",
        channelTitle: "Rick Astley",
        duration: 213,
        viewCount: 1_400_000_000
    ))
    .frame(width: 320)
    .padding()
}
#endif
