import Foundation
import OSLog
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
public actor TTSKitTtsEngine: TtsEngine {
    /// The preset speakers this model ships with, sorted for stable help text and error copy.
    public static let supportedVoices: [String] = Qwen3Speaker.allCases.map(\.rawValue).sorted()
    /// Matches TTSKit's own default speaker.
    public static let defaultVoice: String = Qwen3Speaker.ryan.rawValue
    public static let supportedLanguages: [String] = Qwen3Language.allCases.map(\.rawValue).sorted()
    public static let defaultLanguage: String = Qwen3Language.english.rawValue

    private let variant: TTSModelVariant
    private let downloadBase: URL
    private var kit: TTSKit?
    /// In-flight preparation, shared by concurrent `prepare()` callers so the model is
    /// downloaded and loaded exactly once.
    private var preparationTask: Task<Void, Error>?

    /// - Parameter downloadBase: where model weights are cached; `nil` uses the app's own
    ///   model directory, beside the WhisperKit weights.
    public init(downloadBase: URL? = nil) {
        self.variant = .defaultForCurrentPlatform
        self.downloadBase = downloadBase ?? Self.defaultDownloadBase()
    }

    /// `~/Library/Application Support/TranscriptionStudio/Models/ttskit` — the Hub cache lays
    /// its own repo structure under this, mirroring the WhisperKit download base beside it.
    public static func defaultDownloadBase() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("TranscriptionStudio/Models/ttskit", isDirectory: true)
    }

    // MARK: - Voice + language resolution

    /// The speaker id to synthesize with, defaulting when none was asked for.
    ///
    /// Unknown ids throw. TTSKit itself silently falls back to its default speaker for an
    /// unrecognized string, which would hand a caller a completely different voice without a
    /// word — so the resolution happens here, before the model sees it.
    public static func resolvedVoice(_ voice: String?) throws -> String {
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
    public static func resolvedLanguage(_ language: String?) throws -> String {
        guard let requested = language?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            return defaultLanguage
        }
        guard let resolved = Qwen3Language(rawValue: requested.lowercased()) else {
            throw TtsEngineError.unsupportedLanguage(requested, supported: supportedLanguages)
        }
        return resolved.rawValue
    }

    // MARK: - TtsEngine

    public nonisolated func validate(text: String, voice: String?, language: String?) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TtsEngineError.emptyText
        }
        _ = try Self.resolvedVoice(voice)
        _ = try Self.resolvedLanguage(language)
    }

    public func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
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

    public func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech {
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

    // MARK: - Model preparation

    /// Download-then-load, split the same way `WhisperKitAsrEngine` splits it, so a failure to
    /// fetch the weights is reported as a download failure rather than a generic load error.
    ///
    /// Note for offline use: loading also fetches the tokenizer from the Hub the first time
    /// (TTSKit resolves it from a repo id, not from the downloaded model folder), so the very
    /// first `prepare()` needs the network even once the weights are cached.
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

        onProgress(EnginePreparationProgress(phase: "Loading speech synthesis model", fraction: nil))
        let config = TTSKitConfig(
            model: variant,
            modelFolder: modelFolder,
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
}
