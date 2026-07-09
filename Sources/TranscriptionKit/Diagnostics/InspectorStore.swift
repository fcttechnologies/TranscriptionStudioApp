import Foundation
import Observation

/// The in-app inspector's live model: a bounded ring of pipeline events plus the latest
/// raw model outputs and system-load samples. Main-actor; views observe it directly.
///
/// Raw model outputs land here so the inspector can show *what the models actually said*
/// (per-frame speaker activities, per-segment ASR confidence), not a summary of it.
@MainActor
@Observable
public final class InspectorStore {
    public static let eventCapacity = 2000

    /// Newest-last ring of structured events (capped at `eventCapacity`).
    public private(set) var events: [PipelineEvent] = []
    /// Latest committed + preview diarizer output, per session (frames × 4 activities).
    public private(set) var latestSpeakerFrames: [UUID: SpeakerFrameMatrix] = [:]
    /// Rolling system-load samples (thermal/CPU/memory), newest-last, capped.
    public private(set) var loadSamples: [SystemLoadSample] = []
    public static let loadSampleCapacity = 600

    public init() {}

    public func append(_ event: PipelineEvent) {
        events.append(event)
        if events.count > Self.eventCapacity {
            events.removeFirst(events.count - Self.eventCapacity)
        }
    }

    public func setSpeakerFrames(_ matrix: SpeakerFrameMatrix, for sessionID: UUID) {
        latestSpeakerFrames[sessionID] = matrix
    }

    public func append(_ sample: SystemLoadSample) {
        loadSamples.append(sample)
        if loadSamples.count > Self.loadSampleCapacity {
            loadSamples.removeFirst(loadSamples.count - Self.loadSampleCapacity)
        }
    }

    /// Latest per-stage duration (for the timeline strip): last event per stage carrying one.
    public func latestDurations() -> [PipelineStage: TimeInterval] {
        var out: [PipelineStage: TimeInterval] = [:]
        for event in events {
            if let duration = event.duration { out[event.stage] = duration }
        }
        return out
    }
}

/// The diarizer's raw output for inspection: rows of 4 sigmoid activities, one row per
/// 80ms frame, split into the committed prefix and the provisional (preview) tail.
public struct SpeakerFrameMatrix: Sendable {
    /// frames × speakers (4). Values in [0,1].
    public var activities: [[Float]]
    /// Rows at index >= this are provisional (preview pass, not yet state-committed).
    public var committedFrameCount: Int
    /// Seconds per row.
    public var frameDuration: TimeInterval

    public init(activities: [[Float]], committedFrameCount: Int, frameDuration: TimeInterval = 0.08) {
        self.activities = activities
        self.committedFrameCount = committedFrameCount
        self.frameDuration = frameDuration
    }
}
