import Foundation
import OSLog
import Synchronization
import TTSKit

/// TTSKit-backed `TtsEngine` — on-device Qwen3-TTS through CoreML, from the same
/// `argmax-oss-swift` package WhisperKit and SpeakerKit already come from.
///
/// An actor for the same reason `WhisperKitAsrEngine` is one: the underlying kit is mutable,
/// long-lived state (download → load), and this serializes access so `prepare()` and
/// `synthesize()` can't race each other.
///
/// This is the only file in the app that imports TTSKit. Everything above it — the serve route,
/// the CLI — speaks `TtsEngine`, `SynthesizedSpeech`, and plain voice/language strings.
actor TTSKitTtsEngine: TtsEngine {
    /// The preset speakers this model ships with, sorted for stable help text and error copy.
    static let supportedVoices: [String] = Qwen3Speaker.allCases.map(\.rawValue).sorted()
    /// Matches TTSKit's own default speaker.
    static let defaultVoice: String = Qwen3Speaker.ryan.rawValue
    static let supportedLanguages: [String] = Qwen3Language.allCases.map(\.rawValue).sorted()
    static let defaultLanguage: String = Qwen3Language.english.rawValue

    private let variant: TTSModelVariant
    private let downloadBase: URL
    private var kit: TTSKit?
    /// In-flight preparation, shared by concurrent `prepare()` callers so the model is
    /// downloaded and loaded exactly once.
    private var preparationTask: Task<Void, Error>?

    /// - Parameter downloadBase: where model weights are cached; `nil` uses the app's own
    ///   model directory, beside the WhisperKit weights.
    init(downloadBase: URL? = nil) {
        self.variant = .defaultForCurrentPlatform
        self.downloadBase = downloadBase ?? Self.defaultDownloadBase()
    }

    /// `~/Library/Application Support/TranscriptionStudio/Models/ttskit` — the Hub cache lays
    /// its own repo structure under this, mirroring the WhisperKit download base beside it.
    static func defaultDownloadBase() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("TranscriptionStudio/Models/ttskit", isDirectory: true)
    }

    /// Where the tokenizer's files are cached: under this engine's own download base, never the
    /// Hub client's default.
    ///
    /// That default is `~/Documents/huggingface`, which is TCC-protected — the 24/7 serve
    /// LaunchAgent has no session that can answer a Documents-access prompt, so `open()` there
    /// blocks in the kernel forever and the request never returns. Every file this engine reads
    /// must live outside a protected folder, so the tokenizer is fetched with a Hub client
    /// pinned to the app's own model directory and then loaded from disk by path.
    static func tokenizerFolder(inDownloadBase base: URL) -> URL {
        base.appendingPathComponent("models/\(Qwen3TTSConstants.defaultTokenizerRepo)", isDirectory: true)
    }

    // MARK: - Voice + language resolution

    /// The speaker id to synthesize with, defaulting when none was asked for.
    ///
    /// Unknown ids throw. TTSKit itself silently falls back to its default speaker for an
    /// unrecognized string, which would hand a caller a completely different voice without a
    /// word — so the resolution happens here, before the model sees it.
    static func resolvedVoice(_ voice: String?) throws -> String {
        guard let requested = voice?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            return defaultVoice
        }
        guard let speaker = Qwen3Speaker(rawValue: requested.lowercased()) else {
            throw TtsEngineError.unsupportedVoice(requested, supported: supportedVoices)
        }
        return speaker.rawValue
    }

    /// The language id to synthesize in, defaulting when none was asked for. Unknown ids throw,
    /// for the same reason `resolvedVoice` rejects them.
    static func resolvedLanguage(_ language: String?) throws -> String {
        guard let requested = language?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            return defaultLanguage
        }
        guard let resolved = Qwen3Language(rawValue: requested.lowercased()) else {
            throw TtsEngineError.unsupportedLanguage(requested, supported: supportedLanguages)
        }
        return resolved.rawValue
    }

    // MARK: - TtsEngine

    nonisolated func validate(text: String, voice: String?, language: String?) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TtsEngineError.emptyText
        }
        _ = try Self.resolvedVoice(voice)
        _ = try Self.resolvedLanguage(language)
    }

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        if kit != nil {
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
        kit = try await Self.buildTTSKit(variant: variant, downloadBase: downloadBase, onProgress: onProgress)
    }

    func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech {
        try validate(text: text, voice: voice, language: language)
        let resolvedVoice = try Self.resolvedVoice(voice)
        let resolvedLanguage = try Self.resolvedLanguage(language)
        guard let kit else { throw TtsEngineError.notPrepared }

        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: SpeechResult
        do {
            result = try await kit.generate(text: spoken, voice: resolvedVoice, language: resolvedLanguage)
        } catch {
            throw TtsEngineError.synthesisFailed((error as? LocalizedError)?.errorDescription
                                                 ?? error.localizedDescription)
        }
        guard !result.audio.isEmpty else {
            throw TtsEngineError.synthesisFailed("the model produced no audio")
        }
        Logger.tts.info("""
            Synthesized \(result.audioDuration, format: .fixed(precision: 2), privacy: .public)s \
            in \(result.timings.fullPipeline, format: .fixed(precision: 2), privacy: .public)s \
            (voice \(resolvedVoice, privacy: .public), \(resolvedLanguage, privacy: .public))
            """)
        return SynthesizedSpeech(samples: result.audio, sampleRate: result.sampleRate)
    }

    /// Streaming synthesis: TTSKit's per-step callback hands over each newly decoded audio
    /// buffer (~80 ms), forwarded here as ordered `SynthesizedSpeechChunk`s.
    ///
    /// Generation is forced sequential (`concurrentWorkerCount = 1`) exactly as TTSKit's own
    /// `play` forces it for its streaming strategies — the concurrent path delivers step
    /// callbacks with empty audio and the real audio only after each batch, which is the
    /// opposite of streaming. Cancellation is latched: TTSKit's sentence chunker runs each text
    /// chunk as its own generation loop and a `false` return only breaks the *current* loop, so
    /// the latch keeps answering `false` and every later chunk stops on its first step.
    func synthesizeStreaming(text: String, voice: String?, language: String?,
                                    onChunk: @escaping @Sendable (SynthesizedSpeechChunk) -> Bool) async throws {
        try validate(text: text, voice: voice, language: language)
        let resolvedVoice = try Self.resolvedVoice(voice)
        let resolvedLanguage = try Self.resolvedLanguage(language)
        guard let kit else { throw TtsEngineError.notPrepared }

        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = GenerationOptions()
        options.concurrentWorkerCount = 1

        let sampleRate = kit.sampleRate
        // Guards the state across the callback and the post-run reads below; the callbacks
        // themselves arrive strictly sequentially from the one generation loop, so `onChunk`
        // is deliberately called outside the lock.
        let state = Mutex((cancelled: false, samplesDelivered: 0))
        do {
            _ = try await kit.generate(text: spoken, voice: resolvedVoice, language: resolvedLanguage,
                                       options: options) { progress in
                guard state.withLock({ !$0.cancelled }) else { return false }
                guard !progress.audio.isEmpty else { return true }
                let keepGoing = onChunk(SynthesizedSpeechChunk(samples: progress.audio,
                                                               sampleRate: sampleRate))
                state.withLock { current in
                    current.samplesDelivered += progress.audio.count
                    if !keepGoing { current.cancelled = true }
                }
                return keepGoing
            }
        } catch {
            // A caller-cancelled run isn't a failure — whatever was delivered was wanted.
            guard state.withLock({ $0.cancelled }) else {
                throw TtsEngineError.synthesisFailed((error as? LocalizedError)?.errorDescription
                                                     ?? error.localizedDescription)
            }
            return
        }
        let (cancelled, samplesDelivered) = state.withLock { ($0.cancelled, $0.samplesDelivered) }
        guard cancelled || samplesDelivered > 0 else {
            throw TtsEngineError.synthesisFailed("the model produced no audio")
        }
        Logger.tts.info("""
            Streamed \(Double(samplesDelivered) / Double(sampleRate), format: .fixed(precision: 2), privacy: .public)s \
            of synthesized audio (voice \(resolvedVoice, privacy: .public), \(resolvedLanguage, privacy: .public))\
            \(cancelled ? " — cancelled by the consumer" : "", privacy: .public)
            """)
    }

    // MARK: - Model preparation

    /// Download-then-load, split the same way `WhisperKitAsrEngine` splits it, so a failure to
    /// fetch either half is reported as a download failure rather than a generic load error.
    ///
    /// Both halves are fetched here — the CoreML weights and the tokenizer, which lives in a
    /// different repo — because both must land under this engine's own download base
    /// (see `tokenizerFolder(inDownloadBase:)`). Once they have, `prepare()` is fully offline:
    /// TTSKit loads a tokenizer straight off disk when handed a folder holding `tokenizer.json`,
    /// and only falls back to the Hub when handed a bare repo id.
    private static func buildTTSKit(variant: TTSModelVariant,
                                    downloadBase: URL,
                                    onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws -> TTSKit {
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)

        onProgress(EnginePreparationProgress(phase: "Downloading speech synthesis model", fraction: 0))
        let modelFolder: URL
        do {
            modelFolder = try await TTSKit.download(variant: variant, downloadBase: downloadBase) { progress in
                onProgress(EnginePreparationProgress(phase: "Downloading speech synthesis model",
                                                     fraction: progress.fractionCompleted))
            }
        } catch {
            Logger.tts.error("Model download failed: \(error, privacy: .public)")
            throw TtsEngineError.modelDownloadFailed(underlying: error.localizedDescription)
        }

        let tokenizerFolder = try await downloadTokenizer(downloadBase: downloadBase, onProgress: onProgress)

        onProgress(EnginePreparationProgress(phase: "Loading speech synthesis model", fraction: nil))
        let config = TTSKitConfig(
            model: variant,
            modelFolder: modelFolder,
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            logLevel: .error,
            download: false,
            load: true
        )
        let kit = try await TTSKit(config)
        onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1))
        Logger.tts.info("TTSKit ready: \(variant.description, privacy: .public)")
        return kit
    }

    /// Fetch the tokenizer into the app's own model directory with a Hub client pinned there,
    /// and return the folder to load it from. Already-cached files make this a no-op.
    private static func downloadTokenizer(downloadBase: URL,
                                          onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws -> URL {
        let folder = tokenizerFolder(inDownloadBase: downloadBase)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path) {
            return folder
        }
        onProgress(EnginePreparationProgress(phase: "Downloading speech synthesis tokenizer", fraction: nil))
        do {
            let hub = HubApiWrapper(downloadBase: downloadBase)
            return try await hub.snapshot(
                from: HubApiWrapper.Repo(id: Qwen3TTSConstants.defaultTokenizerRepo),
                matching: ["config.json", "tokenizer.json", "tokenizer_config.json"]
            )
        } catch {
            Logger.tts.error("Tokenizer download failed: \(error, privacy: .public)")
            throw TtsEngineError.modelDownloadFailed(underlying: error.localizedDescription)
        }
    }
}
