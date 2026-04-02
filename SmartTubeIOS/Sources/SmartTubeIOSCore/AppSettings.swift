import Foundation

// MARK: - AppSettings

/// Persisted app-wide preferences (mirrors Android `PlayerData`, `MainUIData`, `GeneralData`, etc.).
public struct AppSettings: Codable {
    // MARK: Player
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

    /// Canonical ordered list of selectable playback speeds — single source of truth.
    public static let availableSpeeds: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    public enum ThemeName: String, Codable, CaseIterable {
        case system = "System"
        case dark   = "Dark"
        case light  = "Light"
    }

    // MARK: Defaults

    public init() {
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
        enabledSections      = [.home, .subscriptions, .history, .playlists, .channels]
        sponsorBlockEnabled  = true
        sponsorBlockCategories = [.sponsor, .selfPromo, .interaction]
        deArrowEnabled       = false
    }
}
