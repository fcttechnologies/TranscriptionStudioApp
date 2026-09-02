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

/// One ASR segment with the model's own quality signals surfaced — the inspector shows
/// these raw (avgLogprob / noSpeechProb / compressionRatio are Whisper's native fields).
struct AsrSegment: Sendable, Codable, Hashable, Identifiable {
    var id: String { "\(track.rawValue)-\(start)-\(end)" }

    let track: AudioTrack
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let avgLogprob: Float
    let noSpeechProb: Float
    let compressionRatio: Float
    let words: [AsrWord]?
    /// Streaming: false while the segment may still be revised by a later window.
    let isConfirmed: Bool

    init(track: AudioTrack,
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

/// The ASR seam. WhisperKit implements it; the mock fakes it; the UI and jobs know
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
    /// (Whisper's auto-detect).
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
