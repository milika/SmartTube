#if canImport(SwiftUI)
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
    @Published public var error: Error?
    @Published public var controlsVisible: Bool = true

    // MARK: - AVPlayer

    public let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObserver: AnyCancellable?
    private var controlsTimer: Task<Void, Never>?

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

            // Related videos
            let related = try? await api.search(query: info.video.title)
            relatedVideos = related?.videos.filter { $0.id != video.id }.prefix(20).map { $0 } ?? []

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
            player.play()
            isPlaying = true
            scheduleControlsHide()
        } catch {
            playerLog.error("❌ loadAsync error: \(String(describing: error), privacy: .public)")
            self.error = error
        }
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        controlsTimer?.cancel()
    }
}
#endif
