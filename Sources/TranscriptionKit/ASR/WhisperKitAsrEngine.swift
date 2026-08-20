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
    /// Both platforms default to large-v3-turbo (the app ships turbo-only). This default also
    /// drives the LIVE-recording engine — NB: if turbo can't keep up with real-time streaming on
    /// iPhone, the fix is a lighter model for the streaming path *only*, not reviving a base default.
    public static let defaultModelNameMac = "openai_whisper-large-v3-v20240930_turbo"
    public static let defaultModelNameiOS = "openai_whisper-large-v3-v20240930_turbo"

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
    /// Force a spoken language (ISO code, e.g. "en"/"es") instead of Whisper's auto-detect.
    private let forcedLanguage: String?
    /// Download the model over a background `URLSession` (see `platformDefaultUseBackgroundDownloadSession`
    /// and the note on `buildWhisperKit` for exactly what this does and doesn't cover).
    private let useBackgroundDownloadSession: Bool
    private var whisperKit: WhisperKit?
    /// In-flight preparation, shared by any concurrent `prepare()` callers so the model
    /// is downloaded/loaded exactly once. Void-returning by design: `WhisperKit` isn't
    /// `Sendable`, so the built instance must never cross a `Task` boundary — `doPrepare`
    /// builds it and assigns `whisperKit` entirely within this actor's isolation.
    private var preparationTask: Task<Void, Error>?

    public init(modelName: String = WhisperKitAsrEngine.platformDefaultModelName,
                downloadBase: URL? = nil,
                forcedLanguage: String? = nil,
                minimumNewAudioSeconds: TimeInterval = 1.0,
                requiredSegmentsForConfirmation: Int = 2,
                useBackgroundDownloadSession: Bool = WhisperKitAsrEngine.platformDefaultUseBackgroundDownloadSession) {
        self.modelName = modelName
        self.downloadBase = downloadBase ?? Self.defaultDownloadBase()
        self.forcedLanguage = forcedLanguage
        self.minimumNewAudioSeconds = minimumNewAudioSeconds
        self.requiredSegmentsForConfirmation = requiredSegmentsForConfirmation
        self.useBackgroundDownloadSession = useBackgroundDownloadSession
    }

    /// iOS apps suspend mid-download when backgrounded, so a model download started there
    /// benefits from a background `URLSession` (the system keeps it running and delivers the
    /// result later). A Mac app isn't suspended the same way, so it keeps the plain foreground
    /// session WhisperKit uses by default.
    public static var platformDefaultUseBackgroundDownloadSession: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
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
        whisperKit = try await Self.buildWhisperKit(modelName: modelName, downloadBase: downloadBase,
                                                    useBackgroundDownloadSession: useBackgroundDownloadSession,
                                                    onProgress: onProgress)
    }

    public func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool) async throws -> [AsrSegment] {
        guard let whisperKit else { throw AsrEngineError.notPrepared }
        guard !samples.isEmpty else { return [] }

        // skipSpecialTokens: segment.text otherwise carries Whisper's raw markers
        // (`<|startoftranscript|>`, `<|4.20|>` …) into transcripts; timings are unaffected
        // (they come from the timestamp tokens, which stay decoded either way).
        var options = DecodingOptions(skipSpecialTokens: true, wordTimestamps: wordTimestamps)
        // NB: no `.vad` chunking here. VAD chunking splits on silence and decodes chunks
        // concurrently, but returns overlapping / out-of-order segments on real audio — the
        // flattened, start-sorted result comes out scrambled AND duplicated (whole passages
        // repeated). WhisperKit's default sequential windowing offsets timestamps correctly,
        // producing a clean in-order transcript at ~the same wall-clock time here, so batch
        // jobs use it. (Live streaming uses its own `clipTimestamps` re-decode loop below.)
        applyBiasing(&options, tokenizer: whisperKit.tokenizer)
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .flatMap(\.segments)
            .sorted { $0.start < $1.start }
            .map { Self.makeSegment(from: $0, track: track, confirmed: true) }
    }

    /// Applies decode biasing — currently just a forced language (if set).
    ///
    /// NOTE: proper-noun conditioning via `DecodingOptions.promptTokens` was tried and
    /// deliberately dropped. The default `large-v3-turbo` variant returns an EMPTY transcript
    /// with *any* prompt (even a single content token) — a turbo/distilled-model
    /// incompatibility with the `startOfPrevious` prefill; the `base` model handles a prompt
    /// fine, so it's variant-specific. The accuracy upside was marginal even where it worked,
    /// so it isn't worth breaking the best model. A future reintroduction must guard on the
    /// variant (skip turbo) or use a different biasing mechanism.
    private func applyBiasing(_ options: inout DecodingOptions, tokenizer: WhisperTokenizer?) {
        if let forcedLanguage { options.language = forcedLanguage }
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

        var options = DecodingOptions(skipSpecialTokens: true, wordTimestamps: false)
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

    /// Background-download note (honesty over polish): `useBackgroundDownloadSession: true`
    /// wires straight through to WhisperKit's own `URLSessionConfiguration.background(withIdentifier:)`
    /// (a real background session, not a foreground one WhisperKit merely tolerates) — this is
    /// the genuine "app starts it, the system finishes it" iOS pattern, and it's essentially
    /// free to turn on since WhisperKit already exposes the hook. What it covers: the app is
    /// backgrounded (not killed) mid-download — the daemon keeps downloading, and the delegate
    /// callback (and this call's `progressCallback`) fires when the app returns to the
    /// foreground. What it does NOT cover on its own: the app being fully terminated
    /// mid-download and needing the OS to relaunch it. That relaunch path requires the app
    /// target's `UIApplicationDelegate` to implement
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` and hand the
    /// stored completion handler to a session reconstructed with WhisperKit's fixed background
    /// identifier (`"swift-transformers.hub.downloader"`) — that hook lives in the app shell
    /// (`Sources/App`), outside this package, and isn't wired here.
    ///
    /// Investigated and deliberately left unwired (2026-07-15): the identifier is owned by
    /// `Downloader`, an `internal` (non-public) class inside the vendored `ArgmaxCore` module
    /// (`External/Hub/Downloader.swift` in the `argmax-oss-swift` package) — WhisperKit exposes
    /// no delegate-injection or session-reconnect API on `WhisperKit.download(...)`. Two
    /// concrete problems follow from that module boundary, not from missing effort:
    /// 1. `Downloader.download(from:)` constructs a **fresh** `URLSession` with this exact
    ///    identifier + its own private delegate on every call (not just at launch). Apple's own
    ///    guidance is that only one session object should own a given background identifier at
    ///    a time; if our app delegate also holds a session on that identifier (to survive a
    ///    terminate-relaunch), the next ordinary transcription's `download` call collides with
    ///    it — undefined behavior per Apple's docs, not a hypothetical.
    /// 2. Even receiving the terminate-relaunch event ourselves buys nothing: finishing a
    ///    download means moving the temp file to the right destination, updating the Hub
    ///    snapshot/resume bookkeeping, and clearing `Downloader`'s own resume state — all of
    ///    that lives in `Downloader`'s private methods and fields. We'd be reimplementing
    ///    ArgmaxCore's downloader, not hooking it.
    /// Doing this properly needs an upstream WhisperKit/ArgmaxCore API (a public delegate hook
    /// or a documented reconnect path) — i.e. it requires forking WhisperKit, which is out of
    /// scope here. In practice this app's launch-time `prewarmDefaultEngine()` call already
    /// re-invokes `download` (and so reattaches to the same background session) the next time
    /// the app runs, so a terminated-mid-download model still resumes/completes on next
    /// launch — just not via the dedicated relaunch-while-backgrounded path a full
    /// implementation would add.
    private static func buildWhisperKit(modelName: String, downloadBase: URL, useBackgroundDownloadSession: Bool,
                                        onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws -> WhisperKit {
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)

        // Phase strings are user-facing (toasts, the mini-player) — human words, never the
        // raw repo variant name; the exact model rides in the logs/metadata instead.
        onProgress(EnginePreparationProgress(phase: "Downloading speech model", fraction: 0))
        let modelFolder: URL
        do {
            modelFolder = try await WhisperKit.download(
                variant: modelName,
                downloadBase: downloadBase,
                useBackgroundSession: useBackgroundDownloadSession
            ) { progress in
                onProgress(EnginePreparationProgress(phase: "Downloading speech model",
                                                     fraction: progress.fractionCompleted))
            }
        } catch {
            Logger.asr.error("Model download failed: \(error, privacy: .public)")
            throw AsrEngineError.modelDownloadFailed(modelName: modelName, underlying: error.localizedDescription)
        }

        onProgress(EnginePreparationProgress(phase: "Loading speech model", fraction: nil))
        // `tokenizerFolder` is where WhisperKit caches the tokenizer, and it must be the app's
        // own model directory: left unset it defaults to the Hub client's `~/Documents/huggingface`,
        // and Documents is TCC-protected. Under the 24/7 serve LaunchAgent there is no session
        // that can answer an access prompt, so reading a tokenizer file there blocks in the
        // kernel forever and a transcription request never returns — the file's metadata is
        // still visible, so the search finds it and then hangs on open.
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: downloadBase,
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
