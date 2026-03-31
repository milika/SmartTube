import Foundation
import AVFoundation
import Combine
import os
import SmartTubeIOSCore

private let playerLog = Logger(subsystem: "com.smarttube.app", category: "Player")

// MARK: - PlaybackViewModel
//
// Manages video playback state and the AVPlayer instance.
// Mirrors the Android `PlaybackPresenter` + `PlayerUIController`.

@MainActor
public final class PlaybackViewModel: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var playerInfo: PlayerInfo?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var availableFormats: [VideoFormat] = []
    @Published public private(set) var sponsorSegments: [SponsorSegment] = []
    @Published public private(set) var relatedVideos: [Video] = []
    @Published public private(set) var hasPrevious: Bool = false
    @Published public private(set) var hasNext: Bool = false
    @Published public var error: Error?
    @Published public var controlsVisible: Bool = true

    // MARK: - History

    /// Videos played before the current one (oldest first).
    private var history: [Video] = []
    /// The video currently loaded (nil before first load).
    private var currentVideo: Video? = nil

    // MARK: - AVPlayer

    public let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObserver: AnyCancellable?
    private var endObserver: AnyCancellable?
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

            playerLog.notice("playerInfo: formats=\(info.formats.count, privacy: .public) hlsURL=\(info.hlsURL?.absoluteString ?? "nil", privacy: .public) dashURL=\(info.dashURL?.absoluteString ?? "nil", privacy: .public)")
            for (i, fmt) in info.formats.enumerated() {
                playerLog.notice("  format[\(i, privacy: .public)] mimeType=\(fmt.mimeType, privacy: .public) quality=\(fmt.label, privacy: .public) url=\(fmt.url?.absoluteString.prefix(80) ?? "nil", privacy: .public)")
            }

            let prefURL = info.preferredStreamURL
            playerLog.notice("preferredStreamURL=\(prefURL?.absoluteString.prefix(120) ?? "nil", privacy: .public)")

            // SponsorBlock
            if settings.sponsorBlockEnabled {
                sponsorSegments = await sponsorBlock.fetchSegments(
                    videoId: video.id,
                    categories: settings.sponsorBlockCategories
                )
            }

            // Related videos — use /next endpoint (mirrors SuggestionsController)
            let related = try? await api.fetchNextInfo(videoId: video.id)
            if let related, !related.isEmpty {
                relatedVideos = related.filter { $0.id != video.id }
                hasNext = !relatedVideos.isEmpty
            } else {
                // Fallback to search if /next returns nothing
                let searched = try? await api.search(query: info.video.title)
                relatedVideos = searched?.videos.filter { $0.id != video.id }.prefix(20).map { $0 } ?? []
                hasNext = !relatedVideos.isEmpty
            }

            // Restore saved watch position (mirrors VideoStateController)
            let savedState = VideoStateStore.shared.state(for: video.id)
            if let pos = savedState?.position, pos > 5 {
                savedPositionToRestore = pos
                playerLog.notice("Restoring position \(Int(pos), privacy: .public)s for \(video.id, privacy: .public)")
            }

            // Build player item
            guard let url = info.preferredStreamURL else {
                playerLog.error("❌ No stream URL available — formats=\(info.formats.count, privacy: .public) hls=\(info.hlsURL != nil, privacy: .public) dash=\(info.dashURL != nil, privacy: .public)")
                throw APIError.decodingError("No stream URL")
            }
            playerLog.notice("Starting AVPlayer with: \(url.absoluteString.prefix(120), privacy: .public)")
            let item = AVPlayerItem(url: url)
            // Observe the item status to catch AVPlayer decoding/network errors
            statusObserver = item.publisher(for: \.status)
                .receive(on: RunLoop.main)
                .sink { [weak self] status in
                    switch status {
                    case .readyToPlay:
                        playerLog.notice("✅ AVPlayerItem readyToPlay")
                        // Restore saved position once the item is ready to seek
                        if let pos = self?.savedPositionToRestore, pos > 0 {
                            self?.savedPositionToRestore = nil
                            self?.seek(to: pos)
                        }
                    case .failed:
                        let err = item.error.map { "\($0)" } ?? "nil"
                        playerLog.error("❌ AVPlayerItem failed: \(err, privacy: .public)")
                        self?.error = item.error
                    case .unknown:
                        playerLog.notice("AVPlayerItem status: unknown (loading)")
                    @unknown default:
                        break
                    }
                }
            player.replaceCurrentItem(with: item)
            duration = info.video.duration ?? 0

            // Autoplay: observe end-of-item and load the next related video
            endObserver?.cancel()
            endObserver = NotificationCenter.default
                .publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.handlePlaybackEnd() }
                }

            player.play()
            isPlaying = true
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

    /// Call this from the time observer; returns true if a seek was triggered.
    @discardableResult
    public func checkSponsorSkip(at time: TimeInterval) -> Bool {
        guard settings.sponsorBlockEnabled else { return false }
        for seg in sponsorSegments where time >= seg.start && time < seg.end {
            seek(to: seg.end)
            return true
        }
        return false
    }

    // MARK: - Time observer

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            self.currentTime = seconds
            self.checkSponsorSkip(at: seconds)
        }
    }

    // MARK: - Cleanup

    public func stop() {
        // Save watch position before stopping (mirrors VideoStateController)
        if let videoId = playerInfo?.video.id, duration > 0 {
            let pos = self.currentTime
            VideoStateStore.shared.save(videoId: videoId, position: pos, duration: duration)
            playerLog.notice("Saved position \(Int(pos), privacy: .public)s for \(videoId, privacy: .public)")
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        controlsTimer?.cancel()
    }
}
