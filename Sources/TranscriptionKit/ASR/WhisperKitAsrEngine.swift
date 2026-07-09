import Foundation
import OSLog
import WhisperKit

/// User-facing failures specific to this engine (WhisperKit's own `WhisperError` is
/// LocalizedError already and propagates as-is for decode/tokenizer failures).
public enum AsrEngineError: LocalizedError, Sendable {
    case notPrepared
    case modelDownloadFailed(modelName: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            "The speech model isn't ready yet — call prepare() first."
        case let .modelDownloadFailed(modelName, underlying):
            "Couldn't download the \(modelName) speech model: \(underlying)"
        }
    }
}

/// WhisperKit-backed `AsrEngine`. An actor: WhisperKit's own model instance is mutable,
/// long-lived state (download → load → prewarm), and this serializes access to it so
/// `prepare()`/`transcribe()`/`stream()` never race each other.
public actor WhisperKitAsrEngine: AsrEngine {
    /// Mac has the RAM/ANE headroom for the large-v3 turbo variant; iOS defaults to the
    /// small, always-resident `base` model. Callers (Settings) can override either.
    public static let defaultModelNameMac = "openai_whisper-large-v3-v20240930_turbo"
    public static let defaultModelNameiOS = "openai_whisper-base"

    public static var platformDefaultModelName: String {
        #if os(macOS)
        defaultModelNameMac
        #else
        defaultModelNameiOS
        #endif
    }

    /// How much *new* audio must accumulate before a streaming decode pass runs — avoids
    /// re-running the encoder/decoder on sub-second dribbles of chunks.
    private let minimumNewAudioSeconds: TimeInterval
    /// The newest N segments from each streaming pass stay unconfirmed (mirrors
    /// WhisperKit's own `AudioStreamTranscriber` default) since the model may still
    /// revise them once more audio (and thus more context) arrives.
    private let requiredSegmentsForConfirmation: Int

    private let modelName: String
    private let downloadBase: URL
    private var whisperKit: WhisperKit?
    /// In-flight preparation, shared by any concurrent `prepare()` callers so the model
    /// is downloaded/loaded exactly once. Void-returning by design: `WhisperKit` isn't
    /// `Sendable`, so the built instance must never cross a `Task` boundary — `doPrepare`
    /// builds it and assigns `whisperKit` entirely within this actor's isolation.
    private var preparationTask: Task<Void, Error>?

    public init(modelName: String = WhisperKitAsrEngine.platformDefaultModelName,
                downloadBase: URL? = nil,
                minimumNewAudioSeconds: TimeInterval = 1.0,
                requiredSegmentsForConfirmation: Int = 2) {
        self.modelName = modelName
        self.downloadBase = downloadBase ?? Self.defaultDownloadBase()
        self.minimumNewAudioSeconds = minimumNewAudioSeconds
        self.requiredSegmentsForConfirmation = requiredSegmentsForConfirmation
    }

    /// `~/Library/Application Support/TranscriptionStudio/Models/whisperkit` — WhisperKit
    /// lays its own `<repo>/<variant>/...` structure under this.
    public static func defaultDownloadBase() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("TranscriptionStudio/Models/whisperkit", isDirectory: true)
    }

    // MARK: - AsrEngine

    public func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        if whisperKit != nil {
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
        whisperKit = try await Self.buildWhisperKit(modelName: modelName, downloadBase: downloadBase, onProgress: onProgress)
    }

    public func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool) async throws -> [AsrSegment] {
        guard let whisperKit else { throw AsrEngineError.notPrepared }
        guard !samples.isEmpty else { return [] }

        var options = DecodingOptions(wordTimestamps: wordTimestamps)
        options.chunkingStrategy = .vad
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .flatMap(\.segments)
            .sorted { $0.start < $1.start }
            .map { Self.makeSegment(from: $0, track: track, confirmed: true) }
    }

    /// Drives its own accumulate-and-decode loop rather than WhisperKit's built-in
    /// `AudioStreamTranscriber`: that actor *owns* the microphone (it calls
    /// `AudioProcessing.startRecordingLive` itself), but our `CaptureSource` abstraction
    /// already delivers normalized `AudioChunk`s from mic, meeting, or mock capture — so
    /// this engine must consume a stream, not drive one. The confirmed/unconfirmed
    /// split and the `clipTimestamps`-based re-decode of the growing buffer are the same
    /// technique `AudioStreamTranscriber` uses internally; only the chunk source differs.
    public nonisolated func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AsrUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.ensurePrepared()
                    try await self.runStreamingLoop(chunks: chunks, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Streaming loop

    private func ensurePrepared() async throws {
        if whisperKit == nil {
            try await prepare(onProgress: { _ in })
        }
    }

    private struct DecodePass {
        let newlyConfirmed: [AsrSegment]
        let unconfirmed: [AsrSegment]
        let confirmedEndTime: TimeInterval
    }

    private func runStreamingLoop(chunks: AsyncThrowingStream<AudioChunk, Error>,
                                  continuation: AsyncThrowingStream<AsrUpdate, Error>.Continuation) async throws {
        guard let whisperKit else { throw AsrEngineError.notPrepared }

        var buffer: [Float] = []
        var track: AudioTrack = .mixed
        var confirmed: [AsrSegment] = []
        var confirmedEndTime: TimeInterval = 0
        var samplesAtLastDecode = 0
        let minimumNewSamples = Int(AudioChunk.sampleRate * minimumNewAudioSeconds)

        for try await chunk in chunks {
            try Task.checkCancellation()
            track = chunk.track
            buffer.append(contentsOf: chunk.samples)
            guard buffer.count - samplesAtLastDecode >= minimumNewSamples else { continue }
            samplesAtLastDecode = buffer.count

            let pass = try await decodePass(whisperKit: whisperKit, buffer: buffer, track: track,
                                            confirmedEndTime: confirmedEndTime)
            confirmed.append(contentsOf: pass.newlyConfirmed)
            confirmedEndTime = pass.confirmedEndTime
            continuation.yield(AsrUpdate(confirmed: confirmed, unconfirmed: pass.unconfirmed))
        }

        // Drain and confirm whatever remains once the source finishes.
        let finalPass = try await decodePass(whisperKit: whisperKit, buffer: buffer, track: track,
                                             confirmedEndTime: confirmedEndTime, confirmAll: true)
        confirmed.append(contentsOf: finalPass.newlyConfirmed)
        continuation.yield(AsrUpdate(confirmed: confirmed, unconfirmed: []))
    }

    private func decodePass(whisperKit: WhisperKit, buffer: [Float], track: AudioTrack,
                            confirmedEndTime: TimeInterval, confirmAll: Bool = false) async throws -> DecodePass {
        guard !buffer.isEmpty else {
            return DecodePass(newlyConfirmed: [], unconfirmed: [], confirmedEndTime: confirmedEndTime)
        }

        var options = DecodingOptions(wordTimestamps: false)
        options.clipTimestamps = [Float(confirmedEndTime)]
        let results = try await whisperKit.transcribe(audioArray: buffer, decodeOptions: options)
        let segments = results.flatMap(\.segments)
            .filter { TimeInterval($0.end) > confirmedEndTime }
            .sorted { $0.start < $1.start }

        guard !segments.isEmpty else {
            return DecodePass(newlyConfirmed: [], unconfirmed: [], confirmedEndTime: confirmedEndTime)
        }

        if confirmAll {
            let all = segments.map { Self.makeSegment(from: $0, track: track, confirmed: true) }
            return DecodePass(newlyConfirmed: all, unconfirmed: [],
                              confirmedEndTime: TimeInterval(segments.last!.end))
        }

        let confirmCount = max(0, segments.count - requiredSegmentsForConfirmation)
        let confirmedSlice = segments.prefix(confirmCount)
        let unconfirmedSlice = segments.suffix(from: confirmCount)
        let newlyConfirmed = confirmedSlice.map { Self.makeSegment(from: $0, track: track, confirmed: true) }
        let unconfirmed = unconfirmedSlice.map { Self.makeSegment(from: $0, track: track, confirmed: false) }
        let newConfirmedEnd = confirmedSlice.last.map { TimeInterval($0.end) } ?? confirmedEndTime
        return DecodePass(newlyConfirmed: newlyConfirmed, unconfirmed: unconfirmed, confirmedEndTime: newConfirmedEnd)
    }

    // MARK: - Model preparation

    private static func buildWhisperKit(modelName: String, downloadBase: URL,
                                        onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws -> WhisperKit {
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)

        onProgress(EnginePreparationProgress(phase: "Downloading \(modelName)", fraction: 0))
        let modelFolder: URL
        do {
            modelFolder = try await WhisperKit.download(
                variant: modelName,
                downloadBase: downloadBase
            ) { progress in
                onProgress(EnginePreparationProgress(phase: "Downloading \(modelName)",
                                                     fraction: progress.fractionCompleted))
            }
        } catch {
            Logger.asr.error("Model download failed: \(error, privacy: .public)")
            throw AsrEngineError.modelDownloadFailed(modelName: modelName, underlying: error.localizedDescription)
        }

        onProgress(EnginePreparationProgress(phase: "Loading model", fraction: nil))
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1))
        Logger.asr.info("WhisperKit ready: \(modelName, privacy: .public)")
        return kit
    }

    /// Internal (not private) so it's unit-testable without a real model download.
    static func makeSegment(from whisperSegment: TranscriptionSegment, track: AudioTrack,
                            confirmed: Bool) -> AsrSegment {
        AsrSegment(
            track: track,
            start: TimeInterval(whisperSegment.start),
            end: TimeInterval(whisperSegment.end),
            text: whisperSegment.text.trimmingCharacters(in: .whitespacesAndNewlines),
            avgLogprob: whisperSegment.avgLogprob,
            noSpeechProb: whisperSegment.noSpeechProb,
            compressionRatio: whisperSegment.compressionRatio,
            words: whisperSegment.words?.map { word in
                AsrWord(word: word.word, start: TimeInterval(word.start), end: TimeInterval(word.end),
                       probability: word.probability)
            },
            isConfirmed: confirmed
        )
    }
}
