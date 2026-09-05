import Foundation

/// One recognized word with its timing and model probability (populated when word
/// timestamps are requested; they cost extra decode time).
struct AsrWord: Sendable, Codable, Hashable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    let probability: Float

    init(word: String, start: TimeInterval, end: TimeInterval, probability: Float) {
        self.word = word
        self.start = start
        self.end = end
        self.probability = probability
    }
}

/// One ASR segment with the model's own confidence surfaced: `avgLogprob` is the log of the
/// mean token probability across the segment, which the inspector shows raw.
struct AsrSegment: Sendable, Codable, Hashable, Identifiable {
    var id: String { "\(track.rawValue)-\(start)-\(end)" }

    let track: AudioTrack
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let avgLogprob: Float
    let words: [AsrWord]?
    /// Streaming: false while the segment may still be revised by a later window.
    let isConfirmed: Bool

    init(track: AudioTrack,
                start: TimeInterval,
                end: TimeInterval,
                text: String,
                avgLogprob: Float = 0,
                words: [AsrWord]? = nil,
                isConfirmed: Bool = true) {
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.avgLogprob = avgLogprob
        self.words = words
        self.isConfirmed = isConfirmed
    }
}

/// A live-transcription state push: the stable prefix plus the still-revisable tail.
struct AsrUpdate: Sendable {
    let confirmed: [AsrSegment]
    let unconfirmed: [AsrSegment]

    init(confirmed: [AsrSegment], unconfirmed: [AsrSegment]) {
        self.confirmed = confirmed
        self.unconfirmed = unconfirmed
    }
}

/// Model preparation progress (download + load + prewarm), for first-run UX.
struct EnginePreparationProgress: Sendable, Equatable {
    let phase: String
    /// 0...1, or nil when indeterminate.
    let fraction: Double?

    init(phase: String, fraction: Double?) {
        self.phase = phase
        self.fraction = fraction
    }
}

/// An engine asked to work before `prepare()` finished.
enum AsrEngineError: LocalizedError, Sendable {
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .notPrepared: "The speech model isn't ready yet — call prepare() first."
        }
    }
}

/// The ASR seam. The routed recognizer implements it; the mock fakes it; the UI and jobs know
/// only this. Session-relative timestamps in, session-relative timestamps out.
protocol AsrEngine: AnyObject, Sendable {
    /// Idempotent: download/load/prewarm the model as needed.
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws

    /// Transcribe a complete 16k mono buffer (file path after ingest, or a finished
    /// recording). Word timestamps on demand.
    func transcribe(samples: [Float],
                    track: AudioTrack,
                    wordTimestamps: Bool) async throws -> [AsrSegment]

    /// The same, with the spoken language decided per call — one loaded model serving callers
    /// that disagree about the language. `nil` leaves the engine's own default in force
    /// (the interface locale's route).
    func transcribe(samples: [Float],
                    track: AudioTrack,
                    wordTimestamps: Bool,
                    language: String?) async throws -> [AsrSegment]

    /// Live transcription over a chunk stream. One stream in, one update stream out;
    /// finishes when the input finishes (emitting the final confirmed state last).
    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AsrUpdate, Error>
}

extension AsrEngine {
    /// An engine with no per-call language control — a fake, or one whose language is fixed at
    /// construction — transcribes the way it always does.
    func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool,
                    language: String?) async throws -> [AsrSegment] {
        try await transcribe(samples: samples, track: track, wordTimestamps: wordTimestamps)
    }
}
