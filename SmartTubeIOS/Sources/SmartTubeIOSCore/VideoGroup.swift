import Foundation

// MARK: - VideoGroup

/// A named collection of videos that maps to an Android `VideoGroup`.
public struct VideoGroup: Identifiable {
    public let id: UUID
    public var title: String?
    public var videos: [Video]
    public var nextPageToken: String?
    public var action: Action
    /// How this group should be laid out in the UI.
    /// `.row` renders as a horizontal scrolling shelf (home feed rows);
    /// `.grid` renders as the default adaptive vertical grid.
    public var layout: Layout

    public enum Action {
        case append
        case replace
        case remove
        case prepend
    }

    public enum Layout {
        case grid
        case row
    }

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        videos: [Video] = [],
        nextPageToken: String? = nil,
        action: Action = .replace,
        layout: Layout = .grid
    ) {
        self.id = id
        self.title = title
        self.videos = videos
        self.nextPageToken = nextPageToken
        self.action = action
        self.layout = layout
    }
}

// MARK: - BrowseSection

/// Represents a tab/section shown in the main browse screen (mirrors Android `BrowseSection`).
public struct BrowseSection: Identifiable, Hashable {
    public let id: String
    public var title: String
    public var type: SectionType

    public enum SectionType: String, CaseIterable, Codable {
        case home          = "home"
        case trending      = "trending"
        case subscriptions = "subscriptions"
        case history       = "history"
        case playlists     = "playlists"
        case channels      = "channels"
        case shorts        = "shorts"
        case music         = "music"
        case news          = "news"
        case gaming        = "gaming"
        case live          = "live"
        case sports        = "sports"
        case settings      = "settings"
    }

    public init(id: String, title: String, type: SectionType) {
        self.id = id
        self.title = title
        self.type = type
    }

    public static let defaultSections: [BrowseSection] = [
        BrowseSection(id: "home",          title: "Home",          type: .home),
        BrowseSection(id: "recommended",   title: "Recommended",   type: .home),
        BrowseSection(id: "subscriptions", title: "Subscriptions", type: .subscriptions),
        BrowseSection(id: "history",       title: "History",       type: .history),
        BrowseSection(id: "playlists",     title: "Playlists",     type: .playlists),
        BrowseSection(id: "channels",      title: "Channels",      type: .channels),
    ]

    /// All known sections including extended categories (music, gaming, etc.).
    public static let allSections: [BrowseSection] = defaultSections + [
        BrowseSection(id: "shorts",  title: "Shorts",  type: .shorts),
        BrowseSection(id: "music",   title: "Music",   type: .music),
        BrowseSection(id: "gaming",  title: "Gaming",  type: .gaming),
        BrowseSection(id: "news",    title: "News",    type: .news),
        BrowseSection(id: "live",    title: "Live",    type: .live),
        BrowseSection(id: "sports",  title: "Sports",  type: .sports),
    ]
}

// MARK: - SearchResult

public struct SearchResult: Identifiable {
    public let id: UUID
    public var videos: [Video]
    public var query: String
    public var nextPageToken: String?

    public init(id: UUID = UUID(), videos: [Video] = [], query: String, nextPageToken: String? = nil) {
        self.id = id
        self.videos = videos
        self.query = query
        self.nextPageToken = nextPageToken
    }
}

// MARK: - Channel

public struct Channel: Identifiable, Hashable, Codable {
    public let id: String   // channelId
    public var title: String
    public var description: String?
    public var thumbnailURL: URL?
    public var subscriberCount: String?
    public var isSubscribed: Bool

    public init(
        id: String,
        title: String,
        description: String? = nil,
        thumbnailURL: URL? = nil,
        subscriberCount: String? = nil,
        isSubscribed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.subscriberCount = subscriberCount
        self.isSubscribed = isSubscribed
    }
}

// MARK: - PlaylistInfo

public struct PlaylistInfo: Identifiable, Codable {
    public let id: String
    public var title: String
    public var videoCount: Int?
    public var thumbnailURL: URL?

    public init(id: String, title: String, videoCount: Int? = nil, thumbnailURL: URL? = nil) {
        self.id = id
        self.title = title
        self.videoCount = videoCount
        self.thumbnailURL = thumbnailURL
    }
}

// MARK: - VideoFormat

public struct VideoFormat: Identifiable, Hashable {
    public let id: UUID
    public var label: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var mimeType: String
    public var url: URL?
    public var bitrate: Int?

    public init(id: UUID = UUID(), label: String, width: Int, height: Int, fps: Int, mimeType: String, url: URL? = nil, bitrate: Int? = nil) {
        self.id = id
        self.label = label
        self.width = width
        self.height = height
        self.fps = fps
        self.mimeType = mimeType
        self.url = url
        self.bitrate = bitrate
    }

    public var qualityLabel: String { "\(height)p\(fps > 30 ? "\(fps)" : "")" }
}

// MARK: - SponsorSegment

/// A SponsorBlock segment within a video.
public struct SponsorSegment: Identifiable, Codable {
    public let id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var category: Category

    public enum Category: String, Codable, CaseIterable {
        case sponsor       = "sponsor"
        case selfPromo     = "selfpromo"
        case interaction   = "interaction"
        case intro         = "intro"
        case outro         = "outro"
        case preview       = "preview"
        case filler        = "filler"
        case musicOfftopic = "music_offtopic"
        case poiHighlight  = "poi_highlight"
    }

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, category: Category) {
        self.id = id
        self.start = start
        self.end = end
        self.category = category
    }
}
