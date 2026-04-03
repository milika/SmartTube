import SwiftUI
import AVFoundation
import SmartTubeIOSCore
#if canImport(UIKit)
import UIKit
#endif

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
    @State private var showSpeedPicker = false
    @State private var showQualityPicker = false

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
                    onSwipeLeft:  { vm.playNext() },
                    onSwipeRight: { vm.playPrevious() },
                    onTap:        { vm.showControls() }
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
            }
        }
        #if os(iOS)
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        #endif
        // Always-visible title badge so XCUITest can read the current video title
        // without waiting for the controls overlay to be shown.
        .overlay(alignment: .topLeading) {
            Text(vm.playerInfo?.video.title ?? video.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.01))   // visually invisible, accessible
                .accessibilityIdentifier("player.titleLabel")
                .padding(.top, 60)
                .padding(.leading, 20)
                .allowsHitTesting(false)
        }
        .onAppear  { vm.load(video: video); vm.setPlaybackSpeed(store.settings.playbackSpeed); vm.updateSettings(store.settings) }
        .onDisappear { vm.stop() }
        .sheet(isPresented: $showSpeedPicker) {
            speedPickerSheet
        }
        .sheet(isPresented: $showQualityPicker) {
            qualityPickerSheet
        }
    }

    // MARK: - Controls overlay

    private func controlsOverlay(size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        VStack {
            // Top bar: back + title
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: AppSymbol.chevronLeft)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.playerInfo?.video.title ?? video.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .accessibilityIdentifier("player.titleLabel")
                    Text(vm.playerInfo?.video.channelTitle ?? video.channelTitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
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

                    Text(formatDuration(vm.currentTime))
                        .padding(.leading, 6)
                    Spacer()
                    Text(formatDuration(vm.duration))
                        .padding(.trailing, 6)

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
        )
        // Allow swipe navigation even when the controls overlay is on screen.
        // .simultaneousGesture fires alongside button taps so seek/pause controls
        // remain interactive while horizontal swipes still drive prev/next.
        .simultaneousGesture(
            DragGesture(minimumDistance: 50, coordinateSpace: .global)
                .onEnded { value in
                    let dx = value.translation.width
                    guard abs(dx) > abs(value.translation.height) else { return }
                    if dx < 0 { vm.playNext() } else { vm.playPrevious() }
                }
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
        Slider(
            value: Binding(
                get: { vm.duration > 0 ? vm.currentTime / vm.duration : 0 },
                set: { vm.seek(to: $0 * vm.duration) }
            ),
            in: 0...1
        )
        .tint(.red)
        .padding(.horizontal, 20)
        .overlay(sponsorBlockMarkers)
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
    }

    // MARK: - Quality picker sheet

    @ViewBuilder
    private var qualityPickerSheet: some View {
        NavigationStack {
            List {
                Button {
                    vm.selectFormat(nil)
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
                }
                .buttonStyle(.plain)
                ForEach(vm.availableFormats) { fmt in
                    Button {
                        vm.selectFormat(fmt)
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
private struct SwipeGestureOverlay: UIViewRepresentable {
    var onSwipeLeft:  () -> Void
    var onSwipeRight: () -> Void
    var onTap:        () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.cancelsTouchesInView = true
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: SwipeGestureOverlay
        private let minDistance: CGFloat = 40

        init(_ parent: SwipeGestureOverlay) { self.parent = parent }

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            guard gr.state == .ended else { return }
            let t = gr.translation(in: gr.view)
            guard abs(t.x) > minDistance, abs(t.x) > abs(t.y) else { return }
            if t.x < 0 { parent.onSwipeLeft() } else { parent.onSwipeRight() }
        }

        @objc func handleTap() { parent.onTap() }
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
