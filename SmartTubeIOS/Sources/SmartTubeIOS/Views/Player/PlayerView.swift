#if canImport(SwiftUI)
import SwiftUI
import AVKit

// MARK: - PlayerView
//
// Full-screen video player.  Wraps AVKit's `VideoPlayer` and overlays
// custom controls, chapter markers, and SponsorBlock skip toasts.
// Mirrors the Android `PlaybackFragment`.

public struct PlayerView: View {
    public let video: Video
    @StateObject private var vm = PlaybackViewModel()
    @Environment(\.dismiss) private var dismiss

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
                    .onTapGesture { vm.showControls() }

                // Custom overlay controls
                if vm.controlsVisible {
                    controlsOverlay(size: geo.size)
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
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onAppear  { vm.load(video: video) }
        .onDisappear { vm.stop() }
        #if os(iOS)
        .ignoresSafeArea(.all)
        #endif
    }

    // MARK: - Controls overlay

    private func controlsOverlay(size: CGSize) -> some View {
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
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Spacer()

            // Centre: rewind / play-pause / forward
            HStack(spacing: 40) {
                seekButton(symbol: "gobackward.10",  seconds: -10)
                playPauseButton
                seekButton(symbol: "goforward.30",  seconds:  30)
            }

            Spacer()

            // Bottom: progress bar
            VStack(spacing: 8) {
                progressBar
                HStack {
                    Text(formatTime(vm.currentTime))
                    Spacer()
                    Text(formatTime(vm.duration))
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
                    .fill(Color.green.opacity(0.7))
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
#endif
