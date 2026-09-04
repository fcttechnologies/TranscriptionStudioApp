import FCTSpeech
import Foundation

/// Transcription Studio's ASR on FCT's own runtime: NVIDIA's Parakeet TDT 0.6B v3, converted by us,
/// encoder on the Neural Engine, decode in Swift (`~/Projects/FCTSpeech`). Covers Parakeet's 25
/// European languages with no language detection; a caller that knows the audio is Chinese,
/// Japanese or Korean routes to the SenseVoice engine instead.
///
/// The models live in the app's support directory under `FCTSpeech/parakeet-v3/` as three
/// `.mlmodelc` directories plus `pieces.json`, installed by the same Background Assets path as the
/// other models. `prepare` compiles nothing: the assets ship compiled for the target OS.
actor FCTSpeechAsrEngine: AsrEngine {
    private let modelsDirectory: URL
    private var transcriber: Transcriber?
    private var preparationTask: Task<Void, Error>?

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    /// `~/Library/Application Support/TranscriptionStudio/Models/fctspeech/parakeet-v3`, beside
    /// the other engines' models.
    static func defaultModelsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("TranscriptionStudio/Models/fctspeech/parakeet-v3", isDirectory: true)
    }

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        if transcriber != nil {
            onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1))
            return
        }
        if let preparationTask {
            try await preparationTask.value
            return
        }
        let task = Task { try await self.doPrepare(onProgress: onProgress) }
        preparationTask = task
        defer { preparationTask = nil }
        try await task.value
    }

    private func doPrepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        onProgress(EnginePreparationProgress(phase: "Loading Parakeet", fraction: 0))
        let models = try ParakeetModels(directory: modelsDirectory)
        transcriber = try Transcriber(models: models, modelsDirectory: modelsDirectory)
        onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1))
    }

    func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool) async throws -> [AsrSegment] {
        guard let transcriber else { throw AsrEngineError.notPrepared }
        guard !samples.isEmpty else { return [] }
        let tokens = try transcriber.transcribe(samples: samples)
        return Self.segments(from: transcriber.words(tokens), track: track, wordTimestamps: wordTimestamps, confirmed: true)
    }

    /// Live: chunks feed a `LiveTranscriber`; a span closing at a pause confirms its words and the
    /// open span's re-decode is the unconfirmed preview. The loop runs on this actor because the
    /// transcriber owns Core ML models, which are not `Sendable`.
    nonisolated func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AsrUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runLive(chunks: chunks) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runLive(chunks: AsyncThrowingStream<AudioChunk, Error>, emit: @Sendable (AsrUpdate) -> Void) async throws {
        guard let transcriber else { throw AsrEngineError.notPrepared }
        let live = LiveTranscriber(transcriber: transcriber)
        var track: AudioTrack = .mixed
        for try await chunk in chunks {
            try Task.checkCancellation()
            track = chunk.track
            if let update = try live.feed(chunk.samples) {
                emit(Self.update(update, track: track))
            }
        }
        emit(Self.update(try live.finish(), track: track))
    }

    private static func update(_ u: LiveTranscriber.Update, track: AudioTrack) -> AsrUpdate {
        AsrUpdate(confirmed: segments(from: u.confirmed, track: track, wordTimestamps: true, confirmed: true),
                  unconfirmed: segments(from: u.unconfirmed, track: track, wordTimestamps: true, confirmed: false))
    }

    /// Words become segments at sentence-ish boundaries: a gap of more than a second, or a word
    /// ending in terminal punctuation, closes one. Segment probability is the mean of its words'.
    static func segments(from words: [Word], track: AudioTrack, wordTimestamps: Bool, confirmed: Bool) -> [AsrSegment] {
        var out: [AsrSegment] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            let p = current.map(\.probability).reduce(0, +) / Float(current.count)
            out.append(AsrSegment(track: track, start: first.start, end: last.end, text: text,
                                  avgLogprob: log(max(p, 1e-6)),
                                  words: wordTimestamps ? current.map { AsrWord(word: $0.text, start: $0.start, end: $0.end, probability: $0.probability) } : nil,
                                  isConfirmed: confirmed))
            current.removeAll(keepingCapacity: true)
        }
        for w in words {
            if let last = current.last, w.start - last.end > 1.0 { flush() }
            current.append(w)
            if let c = w.text.last, ".?!".contains(c) { flush() }
        }
        flush()
        return out
    }
}
