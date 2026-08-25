import Foundation
import Observation

/// The in-app inspector's live model: a bounded ring of pipeline events plus the latest
/// raw model outputs and system-load samples. Main-actor; views observe it directly.
///
/// Raw model outputs land here so the inspector can show *what the models actually said*
/// (per-frame speaker activities, per-segment ASR confidence), not a summary of it.
@MainActor
@Observable
final class InspectorStore {
    static let eventCapacity = 2000

    /// Newest-last ring of structured events (capped at `eventCapacity`).
    private(set) var events: [PipelineEvent] = []
    /// Latest committed + preview diarizer output, per session (frames × 4 activities).
    private(set) var latestSpeakerFrames: [UUID: SpeakerFrameMatrix] = [:]
    /// Rolling system-load samples (thermal/CPU/memory), newest-last, capped.
    private(set) var loadSamples: [SystemLoadSample] = []
    static let loadSampleCapacity = 600

    init() {}

    func append(_ event: PipelineEvent) {
        events.append(event)
        if events.count > Self.eventCapacity {
            events.removeFirst(events.count - Self.eventCapacity)
        }
    }

    func setSpeakerFrames(_ matrix: SpeakerFrameMatrix, for sessionID: UUID) {
        latestSpeakerFrames[sessionID] = matrix
    }

    func append(_ sample: SystemLoadSample) {
        loadSamples.append(sample)
        if loadSamples.count > Self.loadSampleCapacity {
            loadSamples.removeFirst(loadSamples.count - Self.loadSampleCapacity)
        }
    }

    /// Latest per-stage duration (for the timeline strip): last event per stage carrying one.
    func latestDurations() -> [PipelineStage: TimeInterval] {
        var out: [PipelineStage: TimeInterval] = [:]
        for event in events {
            if let duration = event.duration { out[event.stage] = duration }
        }
        return out
    }
}

/// The diarizer's raw output for inspection: rows of 4 sigmoid activities, one row per
/// 80ms frame, split into the committed prefix and the provisional (preview) tail.
struct SpeakerFrameMatrix: Sendable {
    /// frames × speakers (4). Values in [0,1].
    var activities: [[Float]]
    /// Rows at index >= this are provisional (preview pass, not yet state-committed).
    var committedFrameCount: Int
    /// Seconds per row.
    var frameDuration: TimeInterval

    init(activities: [[Float]], committedFrameCount: Int, frameDuration: TimeInterval = 0.08) {
        self.activities = activities
        self.committedFrameCount = committedFrameCount
        self.frameDuration = frameDuration
    }
}
