import FCTSpeech
import Foundation

/// The ASR engine the app uses: the language decides the model, before any audio is heard.
///
/// Parakeet covers 25 European languages and has no language detection: on a language it does
/// not know it returns confident nonsense rather than failing. SenseVoice covers zh, yue, ja, ko
/// (and en) and detects only among those. The two failure sets are exact complements, so the route
/// is decided by the language tag and never by the audio. The tag comes from the app's interface
/// locale by default and from the user's per-session choice when they made one. Every locale the
/// app is translated into is covered; a language outside both sets is refused by name so the user
/// picks one that is, rather than getting a transcript that reads fluently and is wrong.
enum AsrRoute: Equatable {
    case parakeet
    case senseVoice(SenseVoiceLanguage)

    /// Parakeet TDT 0.6B v3's languages, as NVIDIA's card lists them.
    static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt",
        "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    static func route(forTag tag: String) -> AsrRoute? {
        let parts = tag.lowercased().split(separator: "-").map(String.init)
        guard let primary = parts.first, !primary.isEmpty else { return nil }
        switch primary {
        case "zh": return .senseVoice(.zh)
        case "yue": return .senseVoice(.yue)
        case "ja": return .senseVoice(.ja)
        case "ko": return .senseVoice(.ko)
        default: return parakeetLanguages.contains(primary) ? .parakeet : nil
        }
    }
}

enum AsrRouteError: Error, LocalizedError {
    case unsupportedLanguage(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let tag): "Transcription Studio does not transcribe \(tag). Choose a supported language for this recording."
        }
    }
}

/// One engine per route, built on first use and kept warm; the route is decided per call from
/// the language, with the interface locale as the default.
actor RoutedAsrEngine: AsrEngine {
    private let defaultTag: @Sendable () -> String
    private var engines: [String: any AsrEngine] = [:]
    private var lastProgress: (@Sendable (EnginePreparationProgress) -> Void)?

    init(defaultLanguageTag: @escaping @Sendable () -> String = { Locale.current.language.languageCode?.identifier ?? "en" }) {
        self.defaultTag = defaultLanguageTag
    }

    private func engine(for tag: String?) async throws -> any AsrEngine {
        let resolved = tag ?? defaultTag()
        guard let route = AsrRoute.route(forTag: resolved) else { throw AsrRouteError.unsupportedLanguage(resolved) }
        let key: String
        let make: () -> any AsrEngine
        switch route {
        case .parakeet:
            key = "parakeet"; make = { FCTSpeechAsrEngine(modelsDirectory: FCTSpeechAsrEngine.defaultModelsDirectory()) }
        case .senseVoice(let lang):
            key = "sensevoice-\(lang.rawValue)"; make = { SenseVoiceAsrEngine(language: lang) }
        }
        if let e = engines[key] { return e }
        let e = make()
        try await e.prepare(onProgress: lastProgress ?? { _ in })
        engines[key] = e
        return e
    }

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        lastProgress = onProgress
        _ = try await engine(for: nil)     // the default route, warm at launch
    }

    func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool) async throws -> [AsrSegment] {
        try await transcribe(samples: samples, track: track, wordTimestamps: wordTimestamps, language: nil)
    }

    func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool, language: String?) async throws -> [AsrSegment] {
        try await engine(for: language).transcribe(samples: samples, track: track, wordTimestamps: wordTimestamps)
    }

    nonisolated func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AsrUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let e = try await self.engine(for: nil)
                    for try await update in e.stream(chunks: chunks) { continuation.yield(update) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
