import SwiftUI
import AVKit
import SmartTubeIOSCore

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

                // AVKit video player (handles Picture-in-Picture automatically)
                VideoPlayer(player: vm.player)
                    .ignoresSafeArea()

                // Transparent tap target on top of VideoPlayer.
                // AVKit's VideoPlayer swallows gesture recognizers placed on it
                // directly, so we layer a clear view above it to catch taps.
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { vm.showControls() }

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
                    Image(systemName: "chevron.left")
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
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(vm.hasPrevious && !vm.isLoading ? .white : .white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.hasPrevious || vm.isLoading)

                    Text(formatTime(vm.currentTime))
                        .padding(.leading, 6)
                    Spacer()
                    Text(formatTime(vm.duration))
                        .padding(.trailing, 6)

                    // Next video button
                    Button {
                        vm.playNext()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(vm.hasNext && !vm.isLoading ? .white : .white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.hasNext || vm.isLoading)
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
                // Visible only while in a sponsor segment
                if vm.sponsorSegments.contains(where: {
                    vm.currentTime >= $0.start && vm.currentTime < $0.end
                }) {
                    Button("Skip Sponsor") {
                        if let seg = vm.sponsorSegments.first(where: {
                            vm.currentTime >= $0.start && vm.currentTime < $0.end
                        }) {
                            vm.seek(to: seg.end)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .padding()
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.easeInOut, value: vm.currentTime)
    }

    private func errorBanner(_ err: Error) -> some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
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

    // MARK: - Helpers

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(max(t, 0))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
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
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
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
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
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
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
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

// MARK: - RelatedVideosView

/// Embedded within PlayerView on iPad/macOS to show suggestions alongside the player.
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
