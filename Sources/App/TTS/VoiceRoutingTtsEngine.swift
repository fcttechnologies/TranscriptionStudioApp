import Foundation

/// A `TtsEngine` that fronts two engines and routes each request by its voice id: a cloned
/// voice goes to the cloning engine, everything else — including no voice at all — to the
/// preset engine, so today's callers keep today's default voice untouched.
///
/// Preparation is deliberately lazy and per-target: `prepare()` loads nothing, and each
/// synthesis prepares only the engine it routes to. The two models together are north of a
/// gigabyte resident; a day of preset requests must never page in the cloner, and vice versa.
/// The warm-holder above (`WarmTTSEngine`) still governs residency — releasing the router
/// releases whichever inner engines actually loaded.
final class VoiceRoutingTtsEngine: TtsEngine, Sendable {
    private let preset: any TtsEngine
    private let cloning: any TtsEngine
    private let presetVoices: [String]
    private let cloningVoices: Set<String>

    /// The voice lists come in beside the engines because routing (and the "unknown voice"
    /// error copy) must be model-free, and the seam has no voice-listing requirement.
    init(preset: any TtsEngine, presetVoices: [String],
                cloning: any TtsEngine, cloningVoices: [String]) {
        self.preset = preset
        self.cloning = cloning
        self.presetVoices = presetVoices
        self.cloningVoices = Set(cloningVoices)
    }

    /// Every voice either engine offers, sorted for stable error copy.
    var supportedVoices: [String] {
        (presetVoices + cloningVoices).sorted()
    }

    private func target(for voice: String?) -> any TtsEngine {
        guard let voice = voice?.trimmingCharacters(in: .whitespacesAndNewlines),
              cloningVoices.contains(voice) else { return preset }
        return cloning
    }

    // MARK: - TtsEngine

    nonisolated func validate(text: String, voice: String?, language: String?) throws {
        do {
            try target(for: voice).validate(text: text, voice: voice, language: language)
        } catch let TtsEngineError.unsupportedVoice(requested, _) {
            // The target only knows its own roster; the caller should see the whole one.
            throw TtsEngineError.unsupportedVoice(requested, supported: supportedVoices)
        }
    }

    /// Loads nothing (see the type comment); each synthesis prepares its own target.
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1))
    }

    func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech {
        try validate(text: text, voice: voice, language: language)
        let engine = target(for: voice)
        try await engine.prepare { _ in }
        return try await engine.synthesize(text: text, voice: voice, language: language)
    }

    func synthesizeStreaming(text: String, voice: String?, language: String?,
                                    onChunk: @escaping @Sendable (SynthesizedSpeechChunk) -> Bool) async throws {
        try validate(text: text, voice: voice, language: language)
        let engine = target(for: voice)
        try await engine.prepare { _ in }
        try await engine.synthesizeStreaming(text: text, voice: voice, language: language, onChunk: onChunk)
    }
}
