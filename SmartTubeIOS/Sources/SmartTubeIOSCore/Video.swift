import Foundation

// MARK: - Video

/// Mirrors the Android `Video` data model.
public struct Video: Identifiable, Hashable, Codable, Sendable {
    public let id: String                   // videoId
    public var title: String
    public var channelTitle: String
    public var channelId: String?
    public var description: String?
    public var thumbnailURL: URL?
    public var duration: TimeInterval?      // seconds
    public var viewCount: Int?
    public var publishedAt: Date?
    public var isLive: Bool
    public var isUpcoming: Bool
    public var isShort: Bool
    public var watchProgress: Double?       // 0.0 – 1.0
    public var playlistId: String?
    public var playlistIndex: Int?
    public var badges: [String]

    public init(
        id: String,
        title: String,
        channelTitle: String,
        channelId: String? = nil,
        description: String? = nil,
        thumbnailURL: URL? = nil,
        duration: TimeInterval? = nil,
        viewCount: Int? = nil,
        publishedAt: Date? = nil,
        isLive: Bool = false,
        isUpcoming: Bool = false,
        isShort: Bool = false,
        watchProgress: Double? = nil,
        playlistId: String? = nil,
        playlistIndex: Int? = nil,
        badges: [String] = []
    ) {
        self.id = id
        self.title = title
        self.channelTitle = channelTitle
        self.channelId = channelId
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.viewCount = viewCount
        self.publishedAt = publishedAt
        self.isLive = isLive
        self.isUpcoming = isUpcoming
        self.isShort = isShort
        self.watchProgress = watchProgress
        self.playlistId = playlistId
        self.playlistIndex = playlistIndex
        self.badges = badges
    }
}

// MARK: - Convenience helpers

public extension Video {
    var formattedDuration: String {
        guard let duration else { return "" }
        let total = Int(duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    var formattedViewCount: String {
        guard let viewCount else { return "" }
        switch viewCount {
        case 0..<1_000:       return "\(viewCount) views"
        case 1_000..<1_000_000: return String(format: "%.1fK views", Double(viewCount) / 1_000)
        default:              return String(format: "%.1fM views", Double(viewCount) / 1_000_000)
        }
    }

    /// High-quality thumbnail URL using YouTube's image CDN.
    var highQualityThumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }
}
