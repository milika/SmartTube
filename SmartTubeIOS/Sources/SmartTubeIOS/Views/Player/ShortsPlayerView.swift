import SwiftUI
import AVKit
import SmartTubeIOSCore

// MARK: - ShortsPlayerView
//
// Full-screen vertical-swipe player for YouTube Shorts.
// Swipe up advances to the next short; swipe down goes to the previous one.

public struct ShortsPlayerView: View {
    public let videos: [Video]
    public let startIndex: Int

    @State private var vm = PlaybackViewModel()
    @State private var currentIndex: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var store

    public init(videos: [Video], startIndex: Int = 0) {
        self.videos = videos
        self.startIndex = startIndex
        self._currentIndex = State(initialValue: startIndex)
    }

    private var currentVideo: Video { videos[currentIndex] }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: vm.player)
                .ignoresSafeArea()

            // Gesture capture layer — sits above VideoPlayer which swallows touches
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { vm.showControls() }
                .gesture(
                    DragGesture(minimumDistance: 40, coordinateSpace: .global)
                        .onEnded { value in
                            let vertical = value.translation.height
                            let horizontal = abs(value.translation.width)
                            // Only trigger for predominantly vertical swipes
                            guard abs(vertical) > horizontal else { return }
                            if vertical < -40 {
                                goTo(currentIndex + 1)
                            } else if vertical > 40 {
                                goTo(currentIndex - 1)
                            }
                        }
                )

            if vm.controlsVisible {
                shortsOverlay
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: vm.controlsVisible)
            }

            if let err = vm.error {
                Text(err.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        #if os(iOS)
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .ignoresSafeArea()
        .onAppear { loadVideo(at: currentIndex) }
        .onDisappear { vm.stop() }
    }

    // MARK: - Overlay

    private var shortsOverlay: some View {
        VStack(spacing: 0) {
            // Top bar: back + index indicator
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                Spacer()
                Text("\(currentIndex + 1) / \(videos.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.4))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)

            Spacer()

            // Bottom section: navigation hints + title + play-pause
            VStack(spacing: 8) {
                if currentIndex > 0 {
                    Image(systemName: "chevron.up")
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.caption)
                }

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vm.playerInfo?.video.title ?? currentVideo.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(vm.playerInfo?.video.channelTitle ?? currentVideo.channelTitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { vm.togglePlayPause() } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)

                if currentIndex < videos.count - 1 {
                    Image(systemName: "chevron.down")
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.caption)
                }
            }
            .padding(.bottom, 40)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 200)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            )
        }
    }

    // MARK: - Navigation

    private func goTo(_ index: Int) {
        guard index >= 0, index < videos.count else { return }
        currentIndex = index
        loadVideo(at: index)
    }

    private func loadVideo(at index: Int) {
        vm.load(video: videos[index])
        vm.setPlaybackSpeed(store.settings.playbackSpeed)
        vm.updateSettings(store.settings)
    }
}
