import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// The recording Live Activity's contract — shared between the app (which drives the activity
/// from `RecordingController`'s lifecycle) and the widget extension (which renders it on the
/// Lock Screen and in the Dynamic Island). Lean by design: this target is linked by the
/// memory-capped widget extension, so it must never gain a heavy dependency (the ShareKit /
/// BackgroundAssetsKit rule).
nonisolated struct RecordingActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        /// Wall-clock anchor while running, positioned so `now − timerAnchor` is the recording's
        /// elapsed time (pauses excluded) — `Text(_, style: .timer)` then ticks natively with no
        /// activity updates. `nil` while paused.
        var timerAnchor: Date?
        /// Elapsed seconds at the last update — the static clock shown while paused.
        var elapsed: TimeInterval
        var isPaused: Bool
        /// Recent input levels quantized to 0…100, newest last (the live waveform trace).
        var levels: [UInt8]

        init(timerAnchor: Date?, elapsed: TimeInterval, isPaused: Bool, levels: [UInt8]) {
            self.timerAnchor = timerAnchor
            self.elapsed = elapsed
            self.isPaused = isPaused
            self.levels = levels
        }
    }

    var sessionID: UUID
    var startedAt: Date

    init(sessionID: UUID, startedAt: Date) {
        self.sessionID = sessionID
        self.startedAt = startedAt
    }
}
#endif
