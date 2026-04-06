import Foundation
import SwiftUI

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

    /// Per-segment action that controls how each SponsorBlock category is handled.
    /// Mirrors Android's per-category action setting in `SponsorBlockData`.
    public enum SponsorBlockAction: String, Codable, CaseIterable, Sendable {
        /// Automatically skip the segment without user interaction.
        case skip      = "skip"
        /// Show a dismissible toast and let the user manually skip.
        case showToast = "showToast"
        /// Take no action — segment plays through normally.
        case nothing   = "nothing"
    }

    public var sponsorBlockEnabled: Bool
    /// Per-category action. Categories absent from this dict are treated as `.nothing`.
    public var sponsorBlockActions: [SponsorSegment.Category: SponsorBlockAction]
    /// Minimum segment length (seconds). Segments shorter than this value are ignored.
    /// 0 means "accept all" (no filtering). Mirrors Android's `SponsorBlockData.minSegmentDuration`.
    public var sponsorBlockMinSegmentDuration: Double
    /// Channels where SponsorBlock is disabled. Key = channelId, value = display title.
    /// Mirrors Android's `SponsorBlockData.excludedChannels`.
    public var sponsorBlockExcludedChannels: [String: String]

    /// Convenience: the set of categories whose action is not `.nothing`.
    /// Passed to `SponsorBlockService.fetchSegments` so we only fetch relevant segments.
    public var activeSponsorCategories: Set<SponsorSegment.Category> {
        Set(sponsorBlockActions.compactMap { $0.value != .nothing ? $0.key : nil })
    }

    /// Returns the action for a given category (`.nothing` if not configured).
    public func sponsorAction(for category: SponsorSegment.Category) -> SponsorBlockAction {
        sponsorBlockActions[category] ?? .nothing
    }

    // MARK: DeArrow
    public var deArrowEnabled: Bool

    // MARK: YouTube link interception
    /// When `true`, SmartTube registers as a handler for `youtube://` and
    /// `vnd.youtube://` deeplinks and opens them in-app instead of the
    /// official YouTube app. Requires the URL schemes to be registered in
    /// Info.plist (which they are once the user enables this).
    public var overrideYouTubeLinks: Bool

    // MARK: Types

    /// Canonical ordered list of selectable playback speeds — single source of truth.
    public static let availableSpeeds: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    public enum VideoQuality: String, Codable, CaseIterable, Sendable {
        case auto  = "auto"
        case q2160 = "2160p"
        case q1440 = "1440p"
        case q1080 = "1080p"
        case q720  = "720p"
        case q480  = "480p"
        case q360  = "360p"
        case q240  = "240p"
        case q144  = "144p"

        /// The maximum pixel height corresponding to this quality level.
        /// Returns `nil` for `.auto` (no cap).
        public var maxHeight: Int? {
            switch self {
            case .auto:  return nil
            case .q144:  return 144
            case .q240:  return 240
            case .q360:  return 360
            case .q480:  return 480
            case .q720:  return 720
            case .q1080: return 1080
            case .q1440: return 1440
            case .q2160: return 2160
            }
        }

        /// Returns the `VideoQuality` matching an exact pixel height, or `nil` if none matches.
        public static func from(height: Int) -> VideoQuality? {
            allCases.first { $0.maxHeight == height }
        }
    }

    public enum ThemeName: String, Codable, CaseIterable {
        case system = "System"
        case dark   = "Dark"
        case light  = "Light"

        public var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .dark:   return .dark
            case .light:  return .light
            }
        }
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
        defaultSection       = BrowseSection.SectionType.home.rawValue
        compactThumbnails    = false
        hideShorts           = false
        themeName            = .system
        enabledSections      = BrowseSection.defaultSections.map(\.type)
        sponsorBlockEnabled  = true
        // Default actions mirror Android's SponsorBlockData defaults:
        //   sponsor / selfPromo → auto-skip; interaction / intro / preview / musicOfftopic → show toast; others → nothing
        sponsorBlockActions = [
            .sponsor:       .skip,
            .selfPromo:     .skip,
            .interaction:   .showToast,
            .intro:         .showToast,
            .outro:         .nothing,
            .preview:       .showToast,
            .filler:        .nothing,
            .musicOfftopic: .showToast,
            .poiHighlight:  .nothing,
        ]
        sponsorBlockMinSegmentDuration = 0
        sponsorBlockExcludedChannels   = [:]
        deArrowEnabled       = false
        overrideYouTubeLinks = false
    }
}
