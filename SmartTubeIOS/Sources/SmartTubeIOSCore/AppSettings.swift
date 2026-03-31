import Foundation

// MARK: - AppSettings

/// Persisted app-wide preferences (mirrors Android `PlayerData`, `MainUIData`, `GeneralData`, etc.).
public struct AppSettings: Codable {
    // MARK: Player
    public var preferredQuality: VideoQuality
    public var playbackSpeed: Double
    public var autoplayEnabled: Bool
    public var subtitlesEnabled: Bool
    public var subtitlesLanguage: String?
    public var backgroundPlaybackEnabled: Bool
    /// Seconds to seek backward (configurable; default 10 mirrors Android's default).
    public var seekBackSeconds: Int
    /// Seconds to seek forward (configurable; default 30 mirrors Android's default).
    public var seekForwardSeconds: Int

    // MARK: UI
    public var defaultSection: String
    public var compactThumbnails: Bool
    public var hideShorts: Bool
    public var themeName: ThemeName
    /// Ordered list of section types visible in the sidebar/tab bar.
    /// When empty, all default sections are shown.
    public var enabledSections: [BrowseSection.SectionType]

    // MARK: SponsorBlock
    public var sponsorBlockEnabled: Bool
    public var sponsorBlockCategories: Set<SponsorSegment.Category>

    // MARK: DeArrow
    public var deArrowEnabled: Bool

    // MARK: Types

    public enum VideoQuality: String, Codable, CaseIterable {
        case auto  = "Auto"
        case q144  = "144p"
        case q240  = "240p"
        case q360  = "360p"
        case q480  = "480p"
        case q720  = "720p"
        case q1080 = "1080p"
        case q1440 = "1440p"
        case q2160 = "2160p"
        case q4320 = "4320p (8K)"
    }

    public enum ThemeName: String, Codable, CaseIterable {
        case system = "System"
        case dark   = "Dark"
        case light  = "Light"
    }

    // MARK: Defaults

    public init() {
        preferredQuality     = .auto
        playbackSpeed        = 1.0
        autoplayEnabled      = true
        subtitlesEnabled     = false
        subtitlesLanguage    = nil
        backgroundPlaybackEnabled = false
        seekBackSeconds      = 10
        seekForwardSeconds   = 30
        defaultSection       = "home"
        compactThumbnails    = false
        hideShorts           = false
        themeName            = .system
        enabledSections      = [.home, .trending, .subscriptions, .history, .playlists, .channels]
        sponsorBlockEnabled  = true
        sponsorBlockCategories = [.sponsor, .selfPromo, .interaction]
        deArrowEnabled       = false
    }
}
