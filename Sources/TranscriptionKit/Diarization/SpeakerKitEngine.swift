// SpeakerKitEngine — the DiarizationEngine over Argmax's SpeakerKit (Pyannote on CoreML).
//
// This is the SHIPPING-DEFAULT diarizer and the cross-check baseline: it runs entirely on
// CoreML (independent of the blocked Sortformer Core AI path), so the app has a real, working
// "who said what" today, and the inspector's A/B view compares the two once Sortformer loads.
// Full-buffer `diarize()` is implemented; `stream()` throws unsupported (Pyannote is a
// full-clip clustering diarizer, not a streaming one).

import Foundation
import SpeakerKit

/// A module-neutral snapshot of a SpeakerKit result — extracted inside the actor so the
/// `SpeakerKit.DiarizationResult` type (whose name collides with our own contract type and with
/// the module name) never appears in a signature.
private struct RawDiarization: Sendable {
    let frameRate: Float
    let totalFrames: Int
    let speakerCount: Int
    /// (clusterId, startSec, endSec) per segment; clusterId < 0 = noMatch/multiple.
    let segments: [(cluster: Int, start: Double, end: Double)]
}

/// Serializes access to the SpeakerKit instance (loaded once, reused).
private actor SpeakerKitBox {
    private var kit: SpeakerKit?

    func load(onProgress: @Sendable (EnginePreparationProgress) -> Void) async throws {
        if kit != nil { return }
        onProgress(EnginePreparationProgress(phase: "Downloading SpeakerKit models", fraction: nil))
        let config = PyannoteConfig(download: true, load: true, verbose: false)
        kit = try await SpeakerKit(config)
        onProgress(EnginePreparationProgress(phase: "SpeakerKit ready", fraction: 1))
    }

    func diarize(_ samples: [Float]) async throws -> RawDiarization {
        guard let kit else { throw GraphRunnerError.unavailable("SpeakerKit prepare() not called") }
        let result = try await kit.diarize(audioArray: samples)   // type inferred; never named
        let segs = result.segments.map { seg in
            (cluster: seg.speaker.speakerId ?? -1,
             start: Double(seg.startTime),
             end: Double(seg.endTime))
        }
        return RawDiarization(frameRate: result.frameRate,
                              totalFrames: result.totalFrames,
                              speakerCount: result.speakerCount,
                              segments: segs)
    }
}

public final class SpeakerKitEngine: DiarizationEngine, Sendable {
    public let backendName = "SpeakerKit (Pyannote)"
    /// Pyannote is a full-clip clustering diarizer — no live streaming path.
    public let supportsStreaming = false

    private let box = SpeakerKitBox()
    private let recorder: PipelineRecorder?
    private let sessionID: UUID?

    public init(recorder: PipelineRecorder? = nil, sessionID: UUID? = nil) {
        self.recorder = recorder
        self.sessionID = sessionID
    }

    public func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        try await box.load(onProgress: onProgress)
    }

    public func diarize(samples: [Float]) async throws -> DiarizationResult {
        let clock = ContinuousClock()
        let t0 = clock.now
        let raw = try await box.diarize(samples)
        let elapsed = seconds(t0, clock.now)

        let (turns, matrix) = Self.map(raw)
        recorder?.record(PipelineEvent(
            sessionID: sessionID, stage: .diarizeCommit, level: .info,
            message: "SpeakerKit diarize", duration: elapsed,
            metadata: ["speakers": "\(raw.speakerCount)",
                       "turns": "\(turns.count)",
                       "frames": "\(matrix.activities.count)"]))
        return DiarizationResult(turns: turns, frames: matrix)
    }

    /// Pyannote is a full-clip clustering diarizer — no streaming path.
    public func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: GraphRunnerError.unavailable(
                "SpeakerKit does not support streaming; use SortformerEngine for live diarization"))
        }
    }

    // MARK: mapping SpeakerKit -> our contract

    /// Maps SpeakerKit segments into `SpeakerTurn`s + a per-frame activity matrix. Cluster IDs are
    /// remapped to dense 0-based slots (first-seen order), clamped to the 4-speaker contract; the
    /// matrix is rasterized at SpeakerKit's own diarization frame rate.
    fileprivate static func map(_ raw: RawDiarization) -> (turns: [SpeakerTurn], matrix: SpeakerFrameMatrix) {
        let frameRate = raw.frameRate > 0 ? raw.frameRate : 12.5   // Pyannote default (~80ms)
        let frameDuration = 1.0 / Double(frameRate)

        var slotForCluster: [Int: Int] = [:]
        func slot(_ cluster: Int) -> Int {
            if let s = slotForCluster[cluster] { return s }
            let s = min(slotForCluster.count, 3)
            slotForCluster[cluster] = s
            return s
        }

        var turns: [SpeakerTurn] = []
        var maxFrame = raw.totalFrames
        for seg in raw.segments {
            guard seg.cluster >= 0 else { continue }   // skip noMatch / multiple
            let s = slot(seg.cluster)
            turns.append(SpeakerTurn(
                speakerIndex: s, start: seg.start, end: seg.end,
                confidence: 1.0, isCommitted: true))   // hard assignment, not a sigmoid
            maxFrame = max(maxFrame, Int((seg.end / frameDuration).rounded(.up)))
        }
        turns.sort { $0.start < $1.start }

        let frameCount = max(maxFrame, 0)
        var activities = [[Float]](repeating: [0, 0, 0, 0], count: frameCount)
        for turn in turns {
            let startFrame = max(Int(turn.start / frameDuration), 0)
            let endFrame = min(Int((turn.end / frameDuration).rounded(.up)), frameCount)
            guard startFrame < endFrame, (0...3).contains(turn.speakerIndex) else { continue }
            for f in startFrame..<endFrame { activities[f][turn.speakerIndex] = 1 }
        }
        let matrix = SpeakerFrameMatrix(activities: activities,
                                        committedFrameCount: frameCount,
                                        frameDuration: frameDuration)
        return (turns, matrix)
    }

    private func seconds(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> TimeInterval {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
