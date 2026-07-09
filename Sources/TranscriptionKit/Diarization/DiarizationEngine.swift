import Foundation

/// One diarized speaker turn: contiguous frames attributed to one anonymous speaker slot
/// (0–3; Sortformer's architectural max is 4), with the mean sigmoid activity as the
/// turn's confidence. `isCommitted` is false for turns from a preview pass whose frames
/// haven't been folded into streaming state yet — the UI renders those as provisional.
public struct SpeakerTurn: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(speakerIndex)-\(start)-\(end)-\(isCommitted)" }

    public let speakerIndex: Int
    public let start: TimeInterval
    public let end: TimeInterval
    /// Mean winning-speaker activity across the turn's frames, in [0,1].
    public let confidence: Float
    public let isCommitted: Bool

    public init(speakerIndex: Int,
                start: TimeInterval,
                end: TimeInterval,
                confidence: Float,
                isCommitted: Bool = true) {
        self.speakerIndex = speakerIndex
        self.start = start
        self.end = end
        self.confidence = confidence
        self.isCommitted = isCommitted
    }
}

/// A full-buffer diarization result: the segmented turns plus the raw per-frame
/// activities (frames × 4) so the inspector can show exactly what the model said.
public struct DiarizationResult: Sendable {
    public let turns: [SpeakerTurn]
    public let frames: SpeakerFrameMatrix

    public init(turns: [SpeakerTurn], frames: SpeakerFrameMatrix) {
        self.turns = turns
        self.frames = frames
    }
}

/// A streaming diarization push: the whole-session turn timeline as currently known
/// (committed prefix + provisional tail) plus the raw frames for the inspector.
public struct DiarizationUpdate: Sendable {
    public let turns: [SpeakerTurn]
    public let frames: SpeakerFrameMatrix

    public init(turns: [SpeakerTurn], frames: SpeakerFrameMatrix) {
        self.turns = turns
        self.frames = frames
    }
}

/// The diarization seam. The Sortformer Core AI port implements it; SpeakerKit implements
/// it as the cross-check backend; the mock fakes it. 16k mono in, 80ms-frame turns out.
public protocol DiarizationEngine: AnyObject, Sendable {
    /// Human-readable backend name for the inspector's A/B view.
    var backendName: String { get }

    /// Idempotent: download/load/warm the model as needed.
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws

    /// Diarize a complete 16k mono buffer.
    func diarize(samples: [Float]) async throws -> DiarizationResult

    /// Live diarization over a chunk stream (single track). Emits updates on preview
    /// passes and on chunk commits; finishes when the input finishes (final commit last).
    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error>
}
