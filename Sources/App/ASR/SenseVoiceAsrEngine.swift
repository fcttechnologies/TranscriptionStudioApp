import FCTSpeech
import Foundation

/// SenseVoiceSmall on FCT's own runtime, for zh / yue / ja / ko (and en): converted by us, on the
/// Neural Engine, greedy CTC in Swift. Punctuation and inverse text normalization are the model's
/// own (`textNorm`). Models live at `FCTSpeech/sensevoice/` under the app's support directory.
actor SenseVoiceAsrEngine: AsrEngine {
    private let modelsDirectory: URL
    private let language: SenseVoiceLanguage
    private var transcriber: Transcriber?
    private var preparationTask: Task<Void, Error>?

    init(language: SenseVoiceLanguage, modelsDirectory: URL = SenseVoiceAsrEngine.defaultModelsDirectory()) {
        self.language = language
        self.modelsDirectory = modelsDirectory
    }

    static func defaultModelsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptionStudio/Models/fctspeech/sensevoice", isDirectory: true)
    }

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        if transcriber != nil { onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1)); return }
        if let preparationTask { try await preparationTask.value; return }
        let task = Task {
            onProgress(EnginePreparationProgress(phase: "Loading SenseVoice", fraction: 0))
            transcriber = Transcriber(decoder: try SenseVoiceWindowDecoder(directory: modelsDirectory, language: language, textNorm: true))
            onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1))
        }
        preparationTask = task
        defer { preparationTask = nil }
        try await task.value
    }

    func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool) async throws -> [AsrSegment] {
        guard let transcriber else { throw AsrEngineError.notPrepared }
        guard !samples.isEmpty else { return [] }
        let tokens = try transcriber.transcribe(samples: samples)
        return FCTSpeechAsrEngine.segments(from: transcriber.words(tokens), track: track, wordTimestamps: wordTimestamps, confirmed: true)
    }

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
            if let update = try live.feed(chunk.samples) { emit(FCTSpeechAsrEngine.update(update, track: track)) }
        }
        emit(FCTSpeechAsrEngine.update(try live.finish(), track: track))
    }
}
