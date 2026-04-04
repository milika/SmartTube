import Foundation
import AVFoundation
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif
import SmartTubeIOSCore

private let playerLog = Logger(subsystem: appSubsystem, category: "Player")

// MARK: - PlaybackViewModel
//
// Manages video playback state and the AVPlayer instance.
// Mirrors the Android `PlaybackPresenter` + `PlayerUIController`.

@MainActor
@Observable
public final class PlaybackViewModel {

    // MARK: - State

    public private(set) var playerInfo: PlayerInfo?
    public private(set) var isLoading: Bool = false
    public private(set) var isPlaying: Bool = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var availableFormats: [VideoFormat] = []
    public private(set) var selectedFormat: VideoFormat? = nil
    public private(set) var sponsorSegments: [SponsorSegment] = []
    /// The segment currently under the playhead whose action is `.showToast` (nil otherwise).
    public private(set) var currentToastSegment: SponsorSegment? = nil
    public private(set) var relatedVideos: [Video] = []
    public private(set) var chapters: [Chapter] = []
    public private(set) var hasPrevious: Bool = false
    public private(set) var hasNext: Bool = false
    public var error: Error?
    public var controlsVisible: Bool = false
    public private(set) var likeStatus: LikeStatus = .none
    public private(set) var statsForNerdsVisible: Bool = false
    public private(set) var statsSnapshot: StatsForNerdsSnapshot = .empty

    /// The chapter whose start time is closest-but-not-greater-than `currentTime`.
    /// Nil when no chapters are available or the video hasn't started.
    public var currentChapter: Chapter? {
        guard !chapters.isEmpty else { return nil }
        return chapters.last(where: { $0.startTime <= currentTime })
    }

    /// True when there is a chapter ahead of the current playhead position.
    public var hasNextChapter: Bool {
        chapters.contains { $0.startTime > currentTime }
    }

    /// True when the playhead can be moved backward to a chapter boundary —
    /// either to the start of the current chapter (if >3 s in) or to the previous one.
    public var hasPreviousChapter: Bool {
        guard let current = currentChapter else { return false }
        if currentTime - current.startTime > 3 { return true }
        return chapters.contains { $0.startTime < current.startTime }
    }

    // MARK: - History

    /// Videos played before the current one (oldest first).
    private var history: [Video] = []
    /// The video currently loaded (nil before first load).
    private var currentVideo: Video? = nil

    // MARK: - AVPlayer

    public let player = AVPlayer()
    nonisolated(unsafe) private var timeObserver: Any?
    private var itemObserverTask: Task<Void, Never>?
    private var endObserverTask: Task<Void, Never>?
    private var controlsTimer: Task<Void, Never>?
    /// Position to seek to once the AVPlayerItem is ready.
    private var savedPositionToRestore: TimeInterval? = nil

    // MARK: - Dependencies

    private let api: InnerTubeAPI
    private let sponsorBlock: SponsorBlockService
    private let deArrow: DeArrowService
    private var settings: AppSettings

    public init(
        api: InnerTubeAPI = InnerTubeAPI(),
        sponsorBlock: SponsorBlockService = SponsorBlockService(),
        deArrow: DeArrowService = DeArrowService(),
        settings: AppSettings = AppSettings()
    ) {
        self.api = api
        self.sponsorBlock = sponsorBlock
        self.deArrow = deArrow
        self.settings = settings
        setupTimeObserver()
    }

    deinit {
        if let obs = timeObserver { player.removeTimeObserver(obs) }
    }

    // MARK: - Load video

    public func load(video: Video) {
        // Stop and clear the current item immediately so the previous frame
        // is not visible while the next video is loading.
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
        controlsVisible = false
        controlsTimer?.cancel()
        likeStatus = .none
        chapters = []

        // Push the currently playing video onto the history stack before switching
        if let prev = currentVideo {
            history.append(prev)
        }
        currentVideo = video
        hasPrevious = !history.isEmpty
        Task { await loadAsync(video: video) }
    }

    private func loadAsync(video: Video) async {
        isLoading = true
        defer { isLoading = false }
        playerLog.notice("load video id=\(video.id, privacy: .public) title=\(video.title, privacy: .public)")
        do {
            let info = try await api.fetchPlayerInfo(videoId: video.id)
            playerInfo = info
            availableFormats = Self.deduplicatedVideoFormats(info.formats)
            selectedFormat = nil

            playerLog.notice("playerInfo: formats=\(info.formats.count, privacy: .public) hlsURL=\(info.hlsURL?.absoluteString ?? "nil", privacy: .public) dashURL=\(info.dashURL?.absoluteString ?? "nil", privacy: .public)")
            for (i, fmt) in info.formats.enumerated() {
                playerLog.notice("  format[\(i, privacy: .public)] mimeType=\(fmt.mimeType, privacy: .public) quality=\(fmt.label, privacy: .public) url=\(fmt.url?.absoluteString.prefix(80) ?? "nil", privacy: .public)")
            }

            let prefURL = info.preferredStreamURL
            playerLog.notice("preferredStreamURL=\(prefURL?.absoluteString.prefix(120) ?? "nil", privacy: .public)")

            // SponsorBlock
            let channelIsExcluded = video.channelId.map {
                settings.sponsorBlockExcludedChannels.keys.contains($0)
            } ?? false
            if settings.sponsorBlockEnabled, !channelIsExcluded {
                var segments = await sponsorBlock.fetchSegments(
                    videoId: video.id,
                    categories: settings.activeSponsorCategories
                )
                let minDur = settings.sponsorBlockMinSegmentDuration
                if minDur > 0 {
                    segments = segments.filter { ($0.end - $0.start) >= minDur }
                }
                sponsorSegments = segments
            }

            // Related videos + like status — use /next endpoint (mirrors SuggestionsController)
            let nextInfo = try? await api.fetchNextInfo(videoId: video.id)
            if let nextInfo, !nextInfo.relatedVideos.isEmpty {
                relatedVideos = nextInfo.relatedVideos.filter { $0.id != video.id }
                hasNext = !relatedVideos.isEmpty
            } else {
                // Fallback to search if /next returns nothing.
                // Use video.title (from the original Video parameter) — info.video.title
                // can be empty for ads/unplayable content where videoDetails is sparse.
                let fallbackQuery = video.title.isEmpty ? nil : video.title
                if let query = fallbackQuery {
                    let searched = try? await api.search(query: query)
                    relatedVideos = searched?.videos.filter { $0.id != video.id }.prefix(InnerTubeClients.maxVideoResults).map { $0 } ?? []
                    hasNext = !relatedVideos.isEmpty
                }
            }
            // Apply like status returned from the authenticated /next call
            if let status = nextInfo?.likeStatus { likeStatus = status }
            if let ch = nextInfo?.chapters, !ch.isEmpty { chapters = ch }

            // Restore saved watch position (mirrors VideoStateController)
            let savedState = await VideoStateStore.shared.state(for: video.id)
            if let pos = savedState?.position, pos > 5 {
                savedPositionToRestore = pos
                playerLog.notice("Restoring position \(Int(pos), privacy: .public)s for \(video.id, privacy: .public)")
            }

            // Build player item — preferredStreamURL is guaranteed non-nil here because
            // parsePlayerInfo throws APIError.unavailable when streamingData is absent.
            //
            // If the user has set a max resolution (preferredQuality != .auto), select the
            // best available direct-URL format at or below that height instead of the
            // adaptive HLS/DASH stream.
            let resolvedURL: URL
            if settings.preferredQuality != .auto,
               let capped = Self.bestFormat(for: settings.preferredQuality, from: availableFormats),
               let fmtURL = capped.url {
                selectedFormat = capped
                resolvedURL = fmtURL
                playerLog.notice("Quality cap \(settings.preferredQuality.rawValue, privacy: .public) → \(capped.qualityLabel, privacy: .public)")
            } else {
                guard let url = info.preferredStreamURL else {
                    playerLog.error("❌ No stream URL after successful parse (should not happen)")
                    throw APIError.decodingError("No stream URL")
                }
                resolvedURL = url
            }
            playerLog.notice("Starting AVPlayer with: \(resolvedURL.absoluteString.prefix(120), privacy: .public)")
            let item = AVPlayerItem(url: resolvedURL)
            // Observe item status using async/await (withCheckedContinuation is not needed
            // here since we only need to react to status changes, not await them).
            itemObserverTask?.cancel()
            itemObserverTask = Task { [weak self] in
                for await status in item.statusStream {
                    guard let self, !Task.isCancelled else { return }
                    switch status {
                    case .readyToPlay:
                        playerLog.notice("✅ AVPlayerItem readyToPlay")
                        if let pos = self.savedPositionToRestore, pos > 0 {
                            self.savedPositionToRestore = nil
                            self.seek(to: pos)
                        }
                    case .failed:
                        let err = item.error.map { "\($0)" } ?? "nil"
                        playerLog.error("❌ AVPlayerItem failed: \(err, privacy: .public)")
                        self.error = item.error
                    case .unknown:
                        playerLog.notice("AVPlayerItem status: unknown (loading)")
                    @unknown default:
                        break
                    }
                }
            }
            player.replaceCurrentItem(with: item)
            duration = info.video.duration ?? 0

            // Observe end-of-item using NotificationCenter async sequence
            endObserverTask?.cancel()
            endObserverTask = Task { [weak self] in
                let notifications = NotificationCenter.default.notifications(
                    named: AVPlayerItem.didPlayToEndTimeNotification,
                    object: item
                )
                for await _ in notifications {
                    guard let self, !Task.isCancelled else { return }
                    self.handlePlaybackEnd()
                }
            }

            player.play()
            isPlaying = true
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
            scheduleControlsHide()
        } catch {
            playerLog.error("❌ loadAsync error: \(String(describing: error), privacy: .public)")
            self.error = error
        }
    }

    // MARK: - Autoplay

    public func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
    }

    // MARK: - Auth

    /// Forwards the current access token to the InnerTubeAPI actor (mirrors BrowseViewModel).
    public func updateAuthToken(_ token: String?) {
        Task { await api.setAuthToken(token) }
    }

    // MARK: - Stats for Nerds

    public func toggleStatsForNerds() {
        statsForNerdsVisible.toggle()
        if statsForNerdsVisible { updateStatsSnapshot() }
    }

    private func updateStatsSnapshot() {
        guard let item = player.currentItem else {
            statsSnapshot = .empty
            return
        }
        let logEvent = item.accessLog()?.events.last
        let videoId = playerInfo?.video.id ?? currentVideo?.id ?? ""

        // Resolution – prefer actual presentation size, fall back to format metadata
        let presentationSize = item.presentationSize
        let res: String
        if presentationSize.width > 0 && presentationSize.height > 0 {
            res = "\(Int(presentationSize.width))×\(Int(presentationSize.height))"
        } else if let fmt = selectedFormat, fmt.height > 0 {
            res = fmt.width > 0 ? "\(fmt.width)×\(fmt.height)" : "\(fmt.height)p"
        } else {
            res = "—"
        }

        let fps = selectedFormat?.fps ?? 0

        // Codec: if a format is manually selected use its mimeType; otherwise
        // reflect the adaptive stream type (HLS / DASH) or fallback to the
        // best available progressive format.
        let codec: String
        if let fmt = selectedFormat {
            codec = Self.extractCodec(from: fmt.mimeType)
        } else if playerInfo?.hlsURL != nil {
            codec = "HLS"
        } else if playerInfo?.dashURL != nil {
            codec = "DASH"
        } else if let fmt = playerInfo?.formats.first {
            codec = Self.extractCodec(from: fmt.mimeType)
        } else {
            codec = "—"
        }

        let nominalBitrate: String
        if let br = selectedFormat?.bitrate, br > 0 {
            nominalBitrate = Self.formatBitrate(br)
        } else if playerInfo?.hlsURL != nil || playerInfo?.dashURL != nil {
            nominalBitrate = "Adaptive"
        } else if let br = playerInfo?.formats.first?.bitrate, br > 0 {
            nominalBitrate = Self.formatBitrate(br)
        } else {
            nominalBitrate = "—"
        }

        let observedBitrate: String
        if let br = logEvent?.observedBitrate, br > 0 {
            observedBitrate = Self.formatBitrate(Int(br))
        } else {
            observedBitrate = "—"
        }

        let droppedFrames = logEvent.map { $0.numberOfDroppedVideoFrames } ?? 0
        let stalls = logEvent.map { $0.numberOfStalls } ?? 0

        statsSnapshot = StatsForNerdsSnapshot(
            videoId: videoId,
            displayResolution: res,
            fps: fps,
            codec: codec,
            nominalBitrate: nominalBitrate,
            observedBitrate: observedBitrate,
            droppedFrames: droppedFrames,
            stalls: stalls
        )
    }

    private static func extractCodec(from mimeType: String) -> String {
        if mimeType.contains("mpegURL") || mimeType.contains("m3u8") { return "HLS" }
        if let range = mimeType.range(of: #"codecs="([^"]+)""#, options: .regularExpression) {
            let matched = String(mimeType[range])
            if let valueRange = matched.range(of: #"(?<==)[^"]+"#, options: .regularExpression) {
                let codecs = String(matched[valueRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let first = codecs.components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespaces) ?? codecs
                return first.components(separatedBy: ".").first ?? first
            }
        }
        if mimeType.contains("mp4")  { return "mp4" }
        if mimeType.contains("webm") { return "webm" }
        return mimeType.isEmpty ? "—" : mimeType
    }

    private static func formatBitrate(_ bps: Int) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f Mbps", Double(bps) / 1_000_000) }
        if bps >= 1_000     { return String(format: "%.0f kbps", Double(bps) / 1_000) }
        return "\(bps) bps"
    }

    // MARK: - Like / Dislike

    /// Toggles the like state for the current video (optimistic update; rolls back on failure).
    public func like() {
        guard let videoId = currentVideo?.id else { return }
        let prev = likeStatus
        likeStatus = prev == .like ? .none : .like
        Task {
            do {
                if prev == .like {
                    try await api.removeLike(videoId: videoId)
                } else {
                    try await api.like(videoId: videoId)
                }
            } catch {
                self.likeStatus = prev
                playerLog.error("like failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Toggles the dislike state for the current video (optimistic update; rolls back on failure).
    public func dislike() {
        guard let videoId = currentVideo?.id else { return }
        let prev = likeStatus
        likeStatus = prev == .dislike ? .none : .dislike
        Task {
            do {
                if prev == .dislike {
                    try await api.removeLike(videoId: videoId)
                } else {
                    try await api.dislike(videoId: videoId)
                }
            } catch {
                self.likeStatus = prev
                playerLog.error("dislike failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Switch to a specific quality format. Pass `nil` to return to Auto (HLS / preferred stream).
    public func selectFormat(_ format: VideoFormat?) {
        selectedFormat = format
        let url: URL
        if let format {
            guard let fmtURL = format.url else { return }
            url = fmtURL
        } else {
            guard let autoURL = playerInfo?.preferredStreamURL else { return }
            url = autoURL
        }
        let resumePosition = currentTime
        savedPositionToRestore = resumePosition > 0 ? resumePosition : nil
        let item = AVPlayerItem(url: url)
        itemObserverTask?.cancel()
        itemObserverTask = Task { [weak self] in
            for await status in item.statusStream {
                guard let self, !Task.isCancelled else { return }
                switch status {
                case .readyToPlay:
                    if let pos = self.savedPositionToRestore, pos > 0 {
                        self.savedPositionToRestore = nil
                        self.seek(to: pos)
                    }
                case .failed:
                    self.error = item.error
                case .unknown: break
                @unknown default: break
                }
            }
        }
        endObserverTask?.cancel()
        endObserverTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification, object: item
            )
            for await _ in notifications {
                guard let self, !Task.isCancelled else { return }
                self.handlePlaybackEnd()
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        playerLog.notice("Quality → \(format?.qualityLabel ?? "Auto", privacy: .public)")
    }

    /// Returns the highest-quality format whose height is at or below the cap defined
    /// by `quality`. Returns `nil` when `quality` is `.auto` or no suitable format exists.
    private static func bestFormat(for quality: AppSettings.VideoQuality, from formats: [VideoFormat]) -> VideoFormat? {
        guard let maxH = quality.maxHeight else { return nil }
        // formats is already sorted descending by height/fps/bitrate from deduplicatedVideoFormats
        return formats.first { $0.height <= maxH }
    }

    private static func deduplicatedVideoFormats(_ formats: [VideoFormat]) -> [VideoFormat] {
        let candidates = formats.filter { $0.url != nil && $0.height > 0 }
        var seen = Set<String>()
        var result: [VideoFormat] = []
        for fmt in candidates.sorted(by: {
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.fps != $1.fps { return $0.fps > $1.fps }
            return ($0.bitrate ?? 0) > ($1.bitrate ?? 0)
        }) {
            let key = "\(fmt.height):\(fmt.fps)"
            if !seen.contains(key) {
                seen.insert(key)
                result.append(fmt)
            }
        }
        return result
    }

    /// Play the next related video (first in the suggestions list).
    public func playNext() {
        guard let next = relatedVideos.first else { return }
        playerLog.notice("playNext: id=\(next.id, privacy: .public)")
        load(video: next)
    }

    /// Play the most recently played video from the history stack.
    /// Pops the last entry from history; load() will push the current video back so
    /// the user can navigate forward again with playNext() or via suggestions.
    public func playPrevious() {
        guard !history.isEmpty else { return }
        let prev = history.removeLast()
        hasPrevious = !history.isEmpty
        playerLog.notice("playPrevious: id=\(prev.id, privacy: .public)")
        load(video: prev)
    }

    private func handlePlaybackEnd() {
        guard settings.autoplayEnabled, let next = relatedVideos.first else { return }
        playerLog.notice("Autoplay: loading next video id=\(next.id, privacy: .public)")
        load(video: next)
    }

    // MARK: - Playback controls

    public func togglePlayPause() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        showControls()
    }

    public func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor [weak self] in self?.currentTime = time }
        }
        showControls()
    }

    public func seekRelative(seconds: TimeInterval) {
        seek(to: max(0, currentTime + seconds))
    }

    /// Seek to the start of the next chapter.
    public func skipToNextChapter() {
        guard let next = chapters.first(where: { $0.startTime > currentTime }) else { return }
        seek(to: next.startTime)
    }

    /// Seek to the start of the current chapter (if >3 s in) or to the previous chapter.
    public func skipToPreviousChapter() {
        guard let current = currentChapter else { return }
        if currentTime - current.startTime > 3 {
            seek(to: current.startTime)
        } else if let prev = chapters.last(where: { $0.startTime < current.startTime }) {
            seek(to: prev.startTime)
        }
    }

    public func setPlaybackSpeed(_ speed: Double) {
        player.rate = Float(speed)
    }

    // MARK: - Controls visibility

    public func showControls() {
        controlsVisible = true
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        controlsTimer?.cancel()
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                self.controlsVisible = false
            }
        }
    }

    // MARK: - SponsorBlock skip

    /// Call this from the time observer. Handles per-category actions:
    ///   `.skip`      → seeks past the segment automatically.
    ///   `.showToast` → surfaces `currentToastSegment` so the view can show a skip button.
    ///   `.nothing`   → no-op.
    /// Returns true if an auto-seek was triggered.
    @discardableResult
    public func checkSponsorSkip(at time: TimeInterval) -> Bool {
        guard settings.sponsorBlockEnabled else {
            currentToastSegment = nil
            return false
        }
        // Check whether the playhead is inside any active segment.
        if let seg = sponsorSegments.first(where: { time >= $0.start && time < $0.end }) {
            switch settings.sponsorAction(for: seg.category) {
            case .skip:
                currentToastSegment = nil
                seek(to: seg.end)
                return true
            case .showToast:
                currentToastSegment = seg
                return false
            case .nothing:
                currentToastSegment = nil
                return false
            }
        } else {
            currentToastSegment = nil
        }
        return false
    }

    /// Manually skip the segment shown in `currentToastSegment` (called by the view's skip button).
    public func skipToastSegment() {
        guard let seg = currentToastSegment else { return }
        seek(to: seg.end)
        currentToastSegment = nil
    }

    // MARK: - Time observer

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: nil) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = seconds
                self.checkSponsorSkip(at: seconds)
                if self.statsForNerdsVisible { self.updateStatsSnapshot() }
            }
        }
    }

    // MARK: - Cleanup

    public func stop() {
        // Save watch position before stopping (mirrors VideoStateController)
        if let videoId = playerInfo?.video.id, duration > 0 {
            let pos = self.currentTime
            let dur = self.duration
            Task {
                await VideoStateStore.shared.save(videoId: videoId, position: pos, duration: dur)
                playerLog.notice("Saved position \(Int(pos), privacy: .public)s for \(videoId, privacy: .public)")
            }
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        controlsTimer?.cancel()
    }
}

// MARK: - StatsForNerdsSnapshot

/// Snapshot of playback diagnostics for the "Stats for Nerds" overlay.
public struct StatsForNerdsSnapshot: Sendable {
    public var videoId: String
    public var displayResolution: String
    public var fps: Int
    public var codec: String
    public var nominalBitrate: String
    public var observedBitrate: String
    public var droppedFrames: Int
    public var stalls: Int

    public static let empty = StatsForNerdsSnapshot(
        videoId: "",
        displayResolution: "",
        fps: 0,
        codec: "",
        nominalBitrate: "",
        observedBitrate: "",
        droppedFrames: 0,
        stalls: 0
    )
}

// MARK: - AVPlayerItem async helpers

private extension AVPlayerItem {
    /// An `AsyncStream` that emits the item's `status` on each KVO change.
    var statusStream: AsyncStream<AVPlayerItem.Status> {
        AsyncStream { continuation in
            let observer = observe(\.status, options: [.initial, .new]) { item, _ in
                continuation.yield(item.status)
                if item.status == .readyToPlay || item.status == .failed {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in observer.invalidate() }
        }
    }
}
