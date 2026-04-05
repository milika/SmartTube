import SwiftUI
import AVFoundation
import SmartTubeIOSCore
import os
#if canImport(UIKit)
import UIKit
#endif

private let swipeLog = Logger(subsystem: appSubsystem, category: "Player")

// MARK: - PlayerView
//
// Full-screen video player.  Wraps AVKit's `VideoPlayer` and overlays
// custom controls, chapter markers, and SponsorBlock skip toasts.
// Mirrors the Android `PlaybackFragment`.

public struct PlayerView: View {
    public let video: Video
    @State private var vm = PlaybackViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var store
    @Environment(AuthService.self) private var authService
    @State private var showSpeedPicker = false
    @State private var showQualityPicker = false
    @State private var slideOffset: CGFloat = 0
    @State private var isTransitioning = false
    @State private var channelDestination: ChannelDestination?
    @State private var downloadService = VideoDownloadService()
    @State private var downloadAlertItem: DownloadAlertItem?

    public init(video: Video) {
        self.video = video
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // AVPlayerLayerView: bare AVPlayerLayer without AVPlayerViewController.
                // AVPlayerViewController (VideoPlayer) dominates the UIKit accessibility
                // tree, making all overlaid SwiftUI elements invisible to XCUITest.
                // A bare AVPlayerLayer renders video with no accessibility interference.
                AVPlayerLayerView(player: vm.player)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                // Horizontal swipe layer: left → next video, right → previous video.
                // Uses UIKit-level UIPanGestureRecognizer so it fires above AVPlayerLayer.
                SwipeGestureOverlay(
                    onSwipeLeft: {
                        swipeLog.debug("[swipe-overlay] onSwipeLeft — isTransitioning=\(isTransitioning) isScrubbing=\(vm.isScrubbing) controlsVisible=\(vm.controlsVisible) hasNext=\(vm.hasNext)")
                        guard !isTransitioning else { return }
                        if vm.hasNext { performHorizontalTransition(direction: -1, screenWidth: geo.size.width) { vm.playNext() } }
                        else { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 } }
                    },
                    onSwipeRight: {
                        swipeLog.debug("[swipe-overlay] onSwipeRight — isTransitioning=\(isTransitioning) isScrubbing=\(vm.isScrubbing) controlsVisible=\(vm.controlsVisible) hasPrevious=\(vm.hasPrevious)")
                        guard !isTransitioning else { return }
                        if vm.hasPrevious { performHorizontalTransition(direction: 1, screenWidth: geo.size.width) { vm.playPrevious() } }
                        else { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 } }
                    },
                    onTap: { vm.showControls() },
                    onTwoFingerTap: { vm.toggleStatsForNerds() },
                    onPanChanged: { dx in
                        guard !isTransitioning else { return }
                        if (dx < 0 && vm.hasNext) || (dx > 0 && vm.hasPrevious) {
                            slideOffset = dx
                        } else {
                            slideOffset = dx * 0.15
                        }
                    },
                    onSwipeCancelled: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 }
                    },
                    // Disabled during scrubbing so the Slider can claim touches uncontested.
                    isEnabled: !vm.isScrubbing
                )
                .ignoresSafeArea()
                .accessibilityHidden(true)

                // Loading spinner
                if vm.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.5)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: vm.isLoading)
                }

                // Custom overlay controls
                if vm.controlsVisible {
                    controlsOverlay(size: geo.size, safeAreaInsets: geo.safeAreaInsets)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: vm.controlsVisible)
                }

                // Error banner
                if let err = vm.error {
                    errorBanner(err)
                }

                // SponsorBlock skip toast
                sponsorSkipToast

                // Stats for Nerds overlay (toggled by two-finger tap)
                if vm.statsForNerdsVisible {
                    StatsForNerdsOverlay(snapshot: vm.statsSnapshot)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: vm.statsForNerdsVisible)
                }
            }
            .offset(x: slideOffset)
        }
        .background(Color.black.ignoresSafeArea())
        #if os(iOS)
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        #endif
        // Always-visible title badge so XCUITest can read the current video title
        // without waiting for the controls overlay to be shown.
        // Also provides an always-accessible back button for UI automation.
        .overlay(alignment: .topLeading) {
            HStack(spacing: 0) {
                Button { withAnimation(.none) { dismiss() } } label: {
                    Color.clear.frame(width: 60, height: 60)
                }
                .accessibilityIdentifier("player.backButton")
                Text(vm.playerInfo?.video.title ?? video.title)
                    .font(.caption)
                    .opacity(0)   // visually invisible (including emoji), accessible
                    .accessibilityIdentifier("player.titleLabel")
                    .allowsHitTesting(false)
            }
            .padding(.top, 60)
        }
        .onAppear  { vm.load(video: video); vm.setPlaybackSpeed(store.settings.playbackSpeed); vm.updateSettings(store.settings); vm.updateAuthToken(authService.accessToken) }
        .onDisappear { vm.stop() }
        .onChange(of: authService.accessToken) { _, newToken in vm.updateAuthToken(newToken) }
        .sheet(isPresented: $showSpeedPicker) {
            speedPickerSheet
        }
        .sheet(isPresented: $showQualityPicker) {
            qualityPickerSheet
        }
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        .onChange(of: downloadService.state) { _, newState in
            switch newState {
            case .done:
                let title = vm.playerInfo?.video.title ?? video.title
                downloadAlertItem = DownloadAlertItem(title: "Saved to Gallery", message: "\"\(title)\" has been saved to your Photos library.")
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
    }

    // MARK: - Slide transition

    /// Animates the current content off-screen in `direction` (-1 = left, +1 = right),
    /// runs `action` to load the next/previous video, then slides the new content in
    /// from the opposite side.
    private func performHorizontalTransition(direction: CGFloat, screenWidth: CGFloat, action: @escaping () -> Void) {
        isTransitioning = true
        withAnimation(.easeIn(duration: 0.2)) {
            slideOffset = direction * screenWidth
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            action()                                        // load new video, clears AVPlayer
            slideOffset = -direction * screenWidth          // snap to opposite side (off-screen)
            withAnimation(.easeOut(duration: 0.25)) {
                slideOffset = 0                             // slide new content in
            }
            try? await Task.sleep(for: .milliseconds(270))
            isTransitioning = false
        }
    }

    // MARK: - Controls overlay

    private func controlsOverlay(size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        VStack {
            // Top bar: back + title
            HStack {
                Button { withAnimation(.none) { dismiss() } } label: {
                    Image(systemName: AppSymbol.chevronLeft)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .accessibilityIdentifier("player.backButton")
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.playerInfo?.video.title ?? video.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .accessibilityIdentifier("player.titleLabel")
                    let channelId = vm.playerInfo?.video.channelId ?? video.channelId
                    let channelTitle = vm.playerInfo?.video.channelTitle ?? video.channelTitle
                    Button {
                        guard let cid = channelId, !cid.isEmpty else { return }
                        channelDestination = ChannelDestination(channelId: cid)
                    } label: {
                        Text(channelTitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(channelId == nil || channelId?.isEmpty == true)
                }
                Spacer()
                // Speed picker button
                Button {
                    showSpeedPicker = true
                } label: {
                    Text(store.settings.playbackSpeed == 1.0 ? "1×"
                         : "\(store.settings.playbackSpeed, specifier: "%.2g")×")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.4))
                        .clipShape(Capsule())
                }
                // Quality picker button (only shown when direct format URLs are available)
                if !vm.availableFormats.isEmpty {
                    Button {
                        showQualityPicker = true
                    } label: {
                        Text(vm.selectedFormat?.qualityLabel ?? "Auto")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white.opacity(vm.isLoading ? 0.3 : 1))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.4))
                            .clipShape(Capsule())
                    }
                    .disabled(vm.isLoading)
                }
                // Like / Dislike buttons (requires sign-in)
                if authService.isSignedIn {
                    Button { vm.like() } label: {
                        Image(systemName: vm.likeStatus == .like
                              ? "\(AppSymbol.thumbsUp).fill"
                              : AppSymbol.thumbsUp)
                            .font(.system(size: 18))
                            .foregroundStyle(vm.likeStatus == .like ? .yellow : .white)
                            .padding(8)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    Button { vm.dislike() } label: {
                        Image(systemName: vm.likeStatus == .dislike
                              ? "\(AppSymbol.thumbsDown).fill"
                              : AppSymbol.thumbsDown)
                            .font(.system(size: 18))
                            .foregroundStyle(vm.likeStatus == .dislike ? .yellow : .white)
                            .padding(8)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                // Share / Download menu
                Menu {
                    let currentVideo = vm.playerInfo?.video ?? video
                    if let shareURL = URL(string: "https://www.youtube.com/watch?v=\(currentVideo.id)") {
                        ShareLink(item: shareURL) {
                            Label("Share", systemImage: AppSymbol.share)
                        }
                    }
                    Button {
                        downloadService.updateAuthToken(authService.accessToken)
                        downloadService.download(video: currentVideo)
                    } label: {
                        if downloadService.state.isActive {
                            Label("Downloading…", systemImage: AppSymbol.download)
                        } else {
                            Label("Download to Gallery", systemImage: AppSymbol.download)
                        }
                    }
                    .disabled(downloadService.state.isActive)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, max(safeAreaInsets.top, 20))

            Spacer()

            // Centre: rewind / play-pause / forward
            HStack(spacing: 40) {
                seekButton(symbol: "gobackward.\(store.settings.seekBackSeconds)",
                           seconds: -Double(store.settings.seekBackSeconds))
                playPauseButton
                seekButton(symbol: "goforward.\(store.settings.seekForwardSeconds)",
                           seconds: Double(store.settings.seekForwardSeconds))
            }
            .disabled(vm.isLoading)
            .opacity(vm.isLoading ? 0.3 : 1)

            Spacer()

            // Bottom: progress bar + prev/next
            VStack(spacing: 8) {
                // Current chapter title — shown whenever chapters are available
                if let chapter = vm.currentChapter {
                    Text(chapter.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: chapter.title)
                }
                progressBar
                HStack {
                    // Previous video button
                    Button {
                        vm.playPrevious()
                    } label: {
                        Image(systemName: AppSymbol.previousTrack)
                            .font(.system(size: 18))
                            .foregroundStyle(vm.hasPrevious && !vm.isLoading ? .white : .white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.hasPrevious || vm.isLoading)

                    // Previous chapter button — only present when the video has chapters
                    if !vm.chapters.isEmpty {
                        Button {
                            vm.skipToPreviousChapter()
                        } label: {
                            Image(systemName: AppSymbol.previousChapter)
                                .font(.system(size: 18))
                                .foregroundStyle(vm.hasPreviousChapter && !vm.isLoading ? .white : .white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(!vm.hasPreviousChapter || vm.isLoading)
                        .accessibilityIdentifier("player.prevChapterBtn")
                    }

                    Text(formatDuration(vm.currentTime))
                        .padding(.leading, 6)
                    Spacer()
                    Text(formatDuration(vm.duration))
                        .padding(.trailing, 6)

                    // Next chapter button — only present when the video has chapters
                    if !vm.chapters.isEmpty {
                        Button {
                            vm.skipToNextChapter()
                        } label: {
                            Image(systemName: AppSymbol.nextChapter)
                                .font(.system(size: 18))
                                .foregroundStyle(vm.hasNextChapter && !vm.isLoading ? .white : .white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(!vm.hasNextChapter || vm.isLoading)
                        .accessibilityIdentifier("player.nextChapterBtn")
                    }

                    // Next video button
                    Button {
                        vm.playNext()
                    } label: {
                        Image(systemName: AppSymbol.nextTrack)
                            .font(.system(size: 18))
                            .foregroundStyle(vm.hasNext && !vm.isLoading ? .white : .white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.hasNext || vm.isLoading)
                    .accessibilityIdentifier("player.nextBtn")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 20)
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .contentShape(Rectangle())
            .onTapGesture { vm.controlsVisible = false }
        )
    }

    // MARK: - Control elements

    private var playPauseButton: some View {
        Button { vm.togglePlayPause() } label: {
            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 42))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func seekButton(symbol: String, seconds: TimeInterval) -> some View {
        Button { vm.seekRelative(seconds: seconds) } label: {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var progressBar: some View {
        ZStack(alignment: .bottom) {
            // Visible background track for the unfilled portion
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(height: 4)
                .padding(.horizontal, 20)

            Slider(
                value: Binding(
                    get: {
                        let t = vm.isScrubbing ? vm.scrubTime : vm.currentTime
                        return vm.duration > 0 ? t / vm.duration : 0
                    },
                    set: { vm.updateScrub(to: $0 * vm.duration) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing { vm.beginScrubbing() } else { vm.commitScrub() }
                }
            )
            .tint(.red)
            .padding(.horizontal, 20)
            .overlay(sponsorBlockMarkers)
            .overlay(chapterMarkers)

            // Scrub-time tooltip: shown only while dragging, floats above the thumb
            if vm.isScrubbing && vm.duration > 0 {
                GeometryReader { geo in
                    let hPad: CGFloat = 20
                    let trackW = geo.size.width - hPad * 2
                    let fraction = vm.scrubTime / vm.duration
                    let thumbX = hPad + trackW * CGFloat(fraction)
                    let labelW: CGFloat = 64
                    let clampedX = min(max(thumbX, hPad + labelW / 2), geo.size.width - hPad - labelW / 2)

                    Text(formatDuration(vm.scrubTime))
                        .font(.caption.monospacedDigit())
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .frame(width: labelW)
                        .position(x: clampedX, y: geo.size.height / 2 - 30)
                }
            }
        }
    }

    // Chapter tick marks on the progress bar — small white notches at each chapter boundary.
    // Each tick has a 24×44 pt transparent tap area so the user can tap to jump to it.
    private var chapterMarkers: some View {
        GeometryReader { geo in
            ForEach(vm.chapters) { chapter in
                let x = geo.size.width * CGFloat(chapter.startTime / max(vm.duration, 1))
                ZStack {
                    // Invisible enlarged hit area
                    Color.clear
                        .frame(width: 24, height: 44)
                    // Visible tick
                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: 12)
                }
                .contentShape(Rectangle())
                .onTapGesture { vm.seek(to: chapter.startTime) }
                .position(x: x, y: geo.size.height / 2)
            }
        }
    }

    // SponsorBlock segment markers on the progress bar
    private var sponsorBlockMarkers: some View {
        GeometryReader { geo in
            ForEach(vm.sponsorSegments) { seg in
                let x = geo.size.width * CGFloat(seg.start / max(vm.duration, 1))
                let w = geo.size.width * CGFloat((seg.end - seg.start) / max(vm.duration, 1))
                Rectangle()
                    .fill(seg.category.color.opacity(0.8))
                    .frame(width: max(w, 2), height: 4)
                    .position(x: x + w / 2, y: geo.size.height / 2)
            }
        }
    }

    private var sponsorSkipToast: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let seg = vm.currentToastSegment {
                    Button("Skip \(seg.category.displayName)") {
                        vm.skipToastSegment()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(seg.category.color)
                    .padding()
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.easeInOut, value: vm.currentToastSegment?.id)
    }

    private func errorBanner(_ err: Error) -> some View {
        VStack {
            HStack {
                Image(systemName: AppSymbol.warning)
                    .foregroundStyle(.yellow)
                Text(err.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.white)
            }
            .padding()
            .background(.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding()
        .accessibilityIdentifier("player.errorBanner")
    }

    // MARK: - Quality picker sheet

    @ViewBuilder
    private var qualityPickerSheet: some View {
        NavigationStack {
            List {
                Button {
                    vm.selectFormat(nil)
                    store.settings.preferredQuality = .auto
                    showQualityPicker = false
                } label: {
                    HStack {
                        Text("Auto")
                            .foregroundStyle(.primary)
                        Spacer()
                        if vm.selectedFormat == nil {
                            Image(systemName: AppSymbol.checkmark)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(vm.availableFormats) { fmt in
                    Button {
                        vm.selectFormat(fmt)
                        store.settings.preferredQuality = AppSettings.VideoQuality.from(height: fmt.height) ?? .auto
                        showQualityPicker = false
                    } label: {
                        HStack {
                            Text(fmt.qualityLabel)
                                .foregroundStyle(.primary)
                            Spacer()
                            if vm.selectedFormat?.id == fmt.id {
                                Image(systemName: AppSymbol.checkmark)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Quality")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showQualityPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Speed picker sheet

    @ViewBuilder
    private var speedPickerSheet: some View {
        NavigationStack {
            List {
                ForEach(AppSettings.availableSpeeds, id: \.self) { (speed: Double) in
                    Button {
                        store.settings.playbackSpeed = speed
                        vm.setPlaybackSpeed(speed)
                        showSpeedPicker = false
                    } label: {
                        HStack {
                            Text(speed == 1.0 ? "Normal (1\u{d7})" : "\(speed, specifier: "%.2g")\u{d7}")
                                .foregroundStyle(.primary)
                            Spacer()
                            if abs(store.settings.playbackSpeed - speed) < 0.01 {
                                Image(systemName: AppSymbol.checkmark)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Playback Speed")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSpeedPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - StatsForNerdsOverlay

struct StatsForNerdsOverlay: View {
    let snapshot: StatsForNerdsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Video ID",         snapshot.videoId)
            row("Resolution",       snapshot.fps > 0
                    ? "\(snapshot.displayResolution) @ \(snapshot.fps) fps"
                    : snapshot.displayResolution)
            row("Codec",            snapshot.codec)
            row("Nominal Bitrate",  snapshot.nominalBitrate)
            row("Connection Speed", snapshot.observedBitrate)
            row("Dropped Frames",   "\(snapshot.droppedFrames)")
            row("Stalls",           "\(snapshot.stalls)")
            Text("Two-finger tap to dismiss")
                .foregroundStyle(.white.opacity(0.4))
                .font(.system(.caption2, design: .monospaced))
                .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .foregroundStyle(.white.opacity(0.55))
                .frame(minWidth: 130, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .foregroundStyle(.white)
        }
        .font(.system(.caption, design: .monospaced))
    }
}

// MARK: - AVPlayerLayerView

#if os(iOS)
/// Lightweight UIViewRepresentable wrapping an `AVPlayerLayer` directly.
/// Unlike `VideoPlayer` / `AVPlayerViewController`, it does not interfere
/// with the UIKit accessibility tree so SwiftUI overlays remain reachable.
private struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> _PlayerUIView {
        let view = _PlayerUIView()
        view.backgroundColor = .black
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: _PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class _PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - SwipeGestureOverlay (horizontal)

/// Transparent UIKit overlay that captures horizontal swipe and tap gestures.
/// Left swipe → `onSwipeLeft`, right swipe → `onSwipeRight`, tap → `onTap`.
/// Set `isEnabled = false` (e.g. while the progress slider is being scrubbed) to
/// temporarily suppress pan recognition so the scrub drag is not mistaken for a swipe.
private struct SwipeGestureOverlay: UIViewRepresentable {
    var onSwipeLeft:      () -> Void
    var onSwipeRight:     () -> Void
    var onTap:            () -> Void
    var onTwoFingerTap:   () -> Void = {}
    var onPanChanged:     ((CGFloat) -> Void)?
    var onSwipeCancelled: (() -> Void)?
    var isEnabled:        Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.cancelsTouchesInView = true
        view.addGestureRecognizer(pan)
        context.coordinator.pan = pan

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.cancelsTouchesInView = false
        view.addGestureRecognizer(twoFingerTap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.pan?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var parent: SwipeGestureOverlay
        weak var pan: UIPanGestureRecognizer?
        private let minDistance: CGFloat = 40

        init(_ parent: SwipeGestureOverlay) { self.parent = parent }

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            let t = gr.translation(in: gr.view)
            switch gr.state {
            case .changed:
                parent.onPanChanged?(t.x)
            case .ended:
                guard abs(t.x) > minDistance, abs(t.x) > abs(t.y) else {
                    parent.onSwipeCancelled?()
                    return
                }
                if t.x < 0 { parent.onSwipeLeft() } else { parent.onSwipeRight() }
            case .cancelled, .failed:
                parent.onSwipeCancelled?()
            default:
                break
            }
        }

        @objc func handleTap() { parent.onTap() }
        @objc func handleTwoFingerTap() { parent.onTwoFingerTap() }
    }
}
#endif

// MARK: - RelatedVideosView
struct RelatedVideosView: View {
    let videos: [Video]
    let onSelect: (Video) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(videos) { video in
                    VideoCardView(video: video, compact: true)
                        .padding(.horizontal)
                        .onTapGesture { onSelect(video) }
                }
            }
        }
    }
}
