#if os(iOS)
import Foundation
import ActivityKit
import FCTGlanceables
import GlanceKit

// The app-side drivers of the two Live Activities, each a thin policy layer over
// FCTGlanceables' generic `LiveActivityController`: the controllers own the ActivityKit
// lifecycle; these own *when* to start/update/end and how the app's live state maps into the
// GlanceKit content states the widget extension renders.

/// Drives the recording Live Activity from `RecordingController`'s lifecycle. Updates are
/// throttled to ~1/s (the elapsed clock ticks natively in the widget via its timer anchor;
/// updates only refresh the waveform trace and the pause state) and diff-gated so identical
/// states never burn activity budget.
@MainActor
final class RecordingLiveActivityDriver {
    /// How many level buckets the activity's waveform carries — enough to read as a live trace,
    /// small enough to stay far inside the content-state size budget.
    static let levelCount = 24
    /// A recording whose state hasn't refreshed in this window is stale (the app was killed
    /// mid-run; the timer anchor keeps ticking otherwise).
    private let controller = LiveActivityController<RecordingActivityAttributes>(staleAfter: 60)
    private var lastDelivered: RecordingActivityAttributes.ContentState?
    private var lastDeliveredAt = Date.distantPast

    func start(sessionID: UUID) {
        let state = Self.state(elapsed: 0, isPaused: false, levels: [])
        lastDelivered = state
        lastDeliveredAt = .now
        controller.start(attributes: RecordingActivityAttributes(sessionID: sessionID, startedAt: .now),
                         state: state,
                         staleDate: controller.staleDate(from: .now))
    }

    /// Refresh the activity from the recorder's live state. `force` bypasses the 1s throttle
    /// for the moments that must land immediately (pause/resume).
    func update(elapsed: TimeInterval, isPaused: Bool, levels: [Float], force: Bool = false) {
        guard controller.isActive else { return }
        let now = Date.now
        guard force || now.timeIntervalSince(lastDeliveredAt) >= 1 else { return }
        let state = Self.state(elapsed: elapsed, isPaused: isPaused, levels: levels)
        guard state != lastDelivered else { return }
        lastDelivered = state
        lastDeliveredAt = now
        Task { await controller.update(state: state, staleDate: controller.staleDate(from: now)) }
    }

    func end(elapsed: TimeInterval) async {
        guard controller.isActive else { return }
        let state = Self.state(elapsed: elapsed, isPaused: true, levels: [])
        lastDelivered = nil
        await controller.end(state: state, dismissalPolicy: .immediate)
    }

    /// The recorder's live values → the activity's content state. The timer anchor is placed so
    /// `now − anchor == elapsed`, which is what lets the widget's clock tick without updates.
    static func state(elapsed: TimeInterval, isPaused: Bool,
                      levels: [Float]) -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(
            timerAnchor: isPaused ? nil : Date.now.addingTimeInterval(-elapsed),
            elapsed: elapsed,
            isPaused: isPaused,
            levels: ActivityLevels.downsample(levels, to: levelCount))
    }
}

/// Drives the playback Live Activity from `PlaybackController`'s transport. Every state carries
/// the position/rate anchor the widget extrapolates from, so updates happen only on transport
/// discontinuities (play/pause/seek/rate) — never on a timer.
@MainActor
final class PlaybackLiveActivityDriver {
    private let controller = LiveActivityController<PlaybackActivityAttributes>()
    private var activeSessionID: UUID?

    /// Bring the activity in line with the transport: starts it on a session's first play,
    /// updates it while that session stays loaded. (Playback has no meaningful staleness — the
    /// state is exact until the next discontinuity — so no stale date is set.)
    func sync(sessionID: UUID, kind: SessionKind, title: String,
              isPlaying: Bool, position: TimeInterval, duration: TimeInterval, rate: Double) {
        let state = PlaybackActivityAttributes.ContentState(
            title: title, isPlaying: isPlaying, duration: duration,
            position: position, rate: rate, updatedAt: .now)
        if activeSessionID == sessionID, controller.isActive {
            Task { await controller.update(state: state, staleDate: nil) }
        } else if isPlaying {
            activeSessionID = sessionID
            controller.start(attributes: PlaybackActivityAttributes(
                                 sessionID: sessionID,
                                 kindLabel: SessionKindStyle.label(kind),
                                 kindSystemImage: SessionKindStyle.icon(kind)),
                             state: state,
                             staleDate: nil)
        }
    }

    func end(title: String, duration: TimeInterval) async {
        guard controller.isActive else { return }
        activeSessionID = nil
        let state = PlaybackActivityAttributes.ContentState(
            title: title, isPlaying: false, duration: duration,
            position: duration, rate: 0, updatedAt: .now)
        await controller.end(state: state, dismissalPolicy: .immediate)
    }
}
#endif
