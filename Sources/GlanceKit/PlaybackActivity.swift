import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// The playback Live Activity's contract — the session identity is fixed for the activity's
/// life; everything the transport changes (title can be renamed mid-play) rides in the state.
public nonisolated struct PlaybackActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var isPlaying: Bool
        public var duration: TimeInterval
        /// The media position at `updatedAt` — the widget extrapolates the moving playhead from
        /// this plus `rate` (see `PlaybackClock`), so updates only happen on discontinuities.
        public var position: TimeInterval
        /// Playback speed (0 encodes paused-by-completion; `isPlaying` is the display state).
        public var rate: Double
        public var updatedAt: Date

        public init(title: String, isPlaying: Bool, duration: TimeInterval,
                    position: TimeInterval, rate: Double, updatedAt: Date) {
            self.title = title
            self.isPlaying = isPlaying
            self.duration = duration
            self.position = position
            self.rate = rate
            self.updatedAt = updatedAt
        }
    }

    public var sessionID: UUID
    /// The source-kind chip the app shows for this session ("Recording", "File", …).
    public var kindLabel: String
    /// The SF Symbol paired with `kindLabel`.
    public var kindSystemImage: String

    public init(sessionID: UUID, kindLabel: String, kindSystemImage: String) {
        self.sessionID = sessionID
        self.kindLabel = kindLabel
        self.kindSystemImage = kindSystemImage
    }
}
#endif

/// The wall-clock window a playing item spans at its current rate — pure math the widget's
/// self-advancing timer text/progress views are driven by, and the unit tests exercise.
public nonisolated enum PlaybackClock {
    /// The date range `[start, end]` such that "now" progresses through it exactly as the media
    /// plays out at `rate`: `start` is when playback would have begun (position 0) and `end` is
    /// when it will finish. Returns nil when not playing or the values can't span a range
    /// (zero/negative rate or duration, position past the end).
    public static func wallClockSpan(position: TimeInterval,
                                     duration: TimeInterval,
                                     rate: Double,
                                     updatedAt: Date) -> ClosedRange<Date>? {
        guard rate > 0, duration > 0, position <= duration else { return nil }
        let start = updatedAt.addingTimeInterval(-position / rate)
        let end = updatedAt.addingTimeInterval((duration - position) / rate)
        guard start <= end else { return nil }
        return start...end
    }
}
