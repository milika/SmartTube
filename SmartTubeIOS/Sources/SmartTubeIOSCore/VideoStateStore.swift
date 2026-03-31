import Foundation

// MARK: - VideoStateStore
//
// Persists per-video watch position and progress fraction across sessions.
// Mirrors Android's VideoStateService + VideoStateController.
//
// Thread-safe via a serial DispatchQueue; call from any thread.

public final class VideoStateStore {

    // MARK: - State

    public struct State: Codable {
        /// Saved playback position in seconds.
        public var position: TimeInterval
        /// Fraction watched: 0.0 – 1.0
        public var watchedFraction: Double
        /// When this entry was last updated (used for pruning old entries).
        public var timestamp: Date

        public init(position: TimeInterval, watchedFraction: Double) {
            self.position = position
            self.watchedFraction = watchedFraction
            self.timestamp = Date()
        }
    }

    // MARK: - Singleton

    public static let shared = VideoStateStore()

    // MARK: - Private

    private static let udKey = "st_video_states"
    private static let maxEntries = 1_000

    private var states: [String: State] = [:]
    private let queue = DispatchQueue(label: "com.smarttube.videostate", qos: .utility)

    private init() {
        queue.sync { self.load() }
    }

    // MARK: - Public API

    /// Returns the saved state for `videoId`, or nil if nothing was saved.
    public func state(for videoId: String) -> State? {
        queue.sync { states[videoId] }
    }

    /// Persists watch position. Automatically prunes entries near the start
    /// (< 5 s) or near the end (> 95 %) — mirrors Android's RESTORE_POSITION_PERCENTS.
    public func save(videoId: String, position: TimeInterval, duration: TimeInterval) {
        let fraction = duration > 1 ? min(position / duration, 1.0) : 0.0
        queue.async {
            if position > 5, fraction < 0.95 {
                self.states[videoId] = State(position: position, watchedFraction: fraction)
                self.prune()
            } else {
                self.states.removeValue(forKey: videoId)
            }
            self.persist()
        }
    }

    /// Removes any saved position for `videoId` (e.g. when the user finishes watching).
    public func clear(videoId: String) {
        queue.async {
            self.states.removeValue(forKey: videoId)
            self.persist()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.udKey),
              let decoded = try? JSONDecoder().decode([String: State].self, from: data)
        else { return }
        states = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        UserDefaults.standard.set(data, forKey: Self.udKey)
    }

    private func prune() {
        guard states.count > Self.maxEntries else { return }
        let sorted = states.sorted { $0.value.timestamp < $1.value.timestamp }
        sorted.prefix(states.count - Self.maxEntries).forEach { states.removeValue(forKey: $0.key) }
    }
}
