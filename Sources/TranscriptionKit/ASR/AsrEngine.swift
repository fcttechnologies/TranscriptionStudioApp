import Foundation

/// One recognized word with its timing and model probability (populated when word
/// timestamps are requested; they cost extra decode time).
public struct AsrWord: Sendable, Codable, Hashable {
    public let word: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let probability: Float

    public init(word: String, start: TimeInterval, end: TimeInterval, probability: Float) {
        self.word = word
        self.start = start
        self.end = end
        self.probability = probability
    }
}

/// One ASR segment with the model's own quality signals surfaced — the inspector shows
/// these raw (avgLogprob / noSpeechProb / compressionRatio are Whisper's native fields).
public struct AsrSegment: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(track.rawValue)-\(start)-\(end)" }

    public let track: AudioTrack
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let avgLogprob: Float
    public let noSpeechProb: Float
    public let compressionRatio: Float
    public let words: [AsrWord]?
    /// Streaming: false while the segment may still be revised by a later window.
    public let isConfirmed: Bool

    public init(track: AudioTrack,
                start: TimeInterval,
                end: TimeInterval,
                text: String,
                avgLogprob: Float = 0,
                noSpeechProb: Float = 0,
                compressionRatio: Float = 0,
                words: [AsrWord]? = nil,
                isConfirmed: Bool = true) {
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.avgLogprob = avgLogprob
        self.noSpeechProb = noSpeechProb
        self.compressionRatio = compressionRatio
        self.words = words
        self.isConfirmed = isConfirmed
    }
}

/// A live-transcription state push: the stable prefix plus the still-revisable tail.
public struct AsrUpdate: Sendable {
    public let confirmed: [AsrSegment]
    public let unconfirmed: [AsrSegment]

    public init(confirmed: [AsrSegment], unconfirmed: [AsrSegment]) {
        self.confirmed = confirmed
        self.unconfirmed = unconfirmed
    }
}

/// Model preparation progress (download + load + prewarm), for first-run UX.
public struct EnginePreparationProgress: Sendable, Equatable {
    public let phase: String
    /// 0...1, or nil when indeterminate.
    public let fraction: Double?

    public init(phase: String, fraction: Double?) {
        self.phase = phase
        self.fraction = fraction
    }
}

/// The ASR seam. WhisperKit implements it; the mock fakes it; the UI and jobs know
/// only this. Session-relative timestamps in, session-relative timestamps out.
public protocol AsrEngine: AnyObject, Sendable {
    /// Idempotent: download/load/prewarm the model as needed.
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws

    /// Transcribe a complete 16k mono buffer (file path after ingest, or a finished
    /// recording). Word timestamps on demand.
    func transcribe(samples: [Float],
                    track: AudioTrack,
                    wordTimestamps: Bool) async throws -> [AsrSegment]

    /// Live transcription over a chunk stream. One stream in, one update stream out;
    /// finishes when the input finishes (emitting the final confirmed state last).
    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AsrUpdate, Error>
}
