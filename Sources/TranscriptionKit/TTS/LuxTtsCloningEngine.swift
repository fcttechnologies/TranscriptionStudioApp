import FluidAudio
import Foundation
import OSLog
import Synchronization

/// FluidAudio-backed `TtsEngine` — zero-shot voice cloning through the CoreML LuxTTS
/// (ZipVoice-Distill) port, conditioned on the reference clips a `CloningVoiceProfile` names.
/// The second engine behind the seam, beside `TTSKitTtsEngine`'s preset speakers: `voice` is a
/// profile reference id here, a preset speaker name there, and callers can't tell the
/// difference.
///
/// An actor for the same reason the TTSKit engine is one: the underlying models are mutable,
/// long-lived state (download → load), serialized so `prepare()` and `synthesize()` can't race.
/// This and `CloningVoiceProfile` are the only files that import FluidAudio.
///
/// Two port constraints shape the synthesis path, both proven out by the 2026-08-02 bench:
///
/// - **The 5-second prompt contract.** The model truncates the prompt clip to 5.0 s but trusts
///   the transcript it's handed — a transcript describing words past the cut makes it *speak*
///   them. So the prompt transcript is derived, not stored: the clip's first 5.0 s go through
///   word-timestamped ASR (injected — the app owns an ASR engine already) and only words fully
///   inside the window survive (`PromptTranscript`). Derived once per clip content and cached
///   on disk keyed by the clip's mtime, exactly the old Python voicebox's prompt-cache design.
/// - **The ~5.9 s per-call generation cap** (fixed vocoder buckets). Text is sentence-chunked
///   (`SentenceChunker`), one generation per sentence, concatenated; a single sentence that
///   still overflows is split at word boundaries and retried. Fernando rated the bench's
///   sentence-chunked long passage best of the field, so the seams are the shipped behavior —
///   don't "improve" them without a re-listen.
public actor LuxTtsCloningEngine: TtsEngine {
    /// Transcribes 16 kHz mono samples with word timestamps — the prompt-matching ASR seam.
    /// Injected so the serve process reuses its warm WhisperKit engine and tests can fake it.
    public typealias PromptAsr = @Sendable ([Float]) async throws -> [AsrSegment]

    /// English only: the port's G2P is espeak-parity `en-us` — other languages would
    /// phonemize wrong, not just sound accented.
    public static let supportedLanguages = ["en", "english"]

    private let profile: CloningVoiceProfile
    private let downloadBase: URL
    private let promptAsr: PromptAsr
    private var manager: LuxTtsManager?
    /// In-flight preparation, shared by concurrent `prepare()` callers so the models are
    /// downloaded and loaded exactly once.
    private var preparationTask: Task<Void, Error>?
    /// voice id → matched prompt transcript, resident so a warm engine derives each once.
    private var promptTexts: [String: String] = [:]

    /// - Parameters:
    ///   - profile: the voice roster (already loaded — see `CloningVoiceProfile.load`).
    ///   - downloadBase: where model weights and the prompt-transcript cache live; `nil` uses
    ///     the app's own model directory. Never a TCC-protected folder: the 24/7 serve
    ///     LaunchAgent reads these files with no session to answer an access prompt.
    ///   - promptAsr: word-timestamped ASR over 16 kHz mono samples.
    public init(profile: CloningVoiceProfile, downloadBase: URL? = nil,
                promptAsr: @escaping PromptAsr) {
        self.profile = profile
        self.downloadBase = downloadBase ?? Self.defaultDownloadBase()
        self.promptAsr = promptAsr
    }

    /// `~/Library/Application Support/TranscriptionStudio/Models/luxtts` — beside the
    /// WhisperKit and TTSKit bases, and outside every TCC-protected folder.
    public static func defaultDownloadBase() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("TranscriptionStudio/Models/luxtts", isDirectory: true)
    }

    // MARK: - Voice + language resolution

    /// The reference to clone from, defaulting to the profile's primary. Unknown ids throw —
    /// same discipline as the preset engine: never quietly substitute a voice.
    private nonisolated func resolvedReference(_ voice: String?) throws -> CloningVoiceProfile.Reference {
        guard let requested = voice?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            return profile.references[profile.primaryVoice]!  // load() guarantees the primary resolves
        }
        guard let reference = profile.references[requested] else {
            throw TtsEngineError.unsupportedVoice(requested, supported: profile.voiceIDs)
        }
        return reference
    }

    // MARK: - TtsEngine

    public nonisolated func validate(text: String, voice: String?, language: String?) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TtsEngineError.emptyText
        }
        _ = try resolvedReference(voice)
        if let requested = language?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty,
           !Self.supportedLanguages.contains(requested.lowercased()) {
            throw TtsEngineError.unsupportedLanguage(requested, supported: Self.supportedLanguages)
        }
    }

    public func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        if manager != nil {
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
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        onProgress(EnginePreparationProgress(phase: "Downloading voice cloning model", fraction: nil))
        let manager = LuxTtsManager(directory: downloadBase)
        do {
            try await manager.initialize()
        } catch {
            Logger.tts.error("LuxTTS preparation failed: \(error, privacy: .public)")
            throw TtsEngineError.modelDownloadFailed(underlying: humanReadable(error))
        }
        self.manager = manager
        onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1))
        Logger.tts.info("LuxTTS cloning engine ready")
    }

    public func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech {
        // A Mutex only because `onChunk` is @Sendable by the seam's signature; the chunks
        // actually arrive strictly in order from the sentence loop below.
        let accumulated = Mutex<[Float]>([])
        try await synthesizeStreaming(text: text, voice: voice, language: language) { chunk in
            accumulated.withLock { $0.append(contentsOf: chunk.samples) }
            return true
        }
        return SynthesizedSpeech(samples: accumulated.withLock { $0 },
                                 sampleRate: LuxTtsConstants.outputSampleRate)
    }

    /// Sentence-streaming synthesis: each sentence's audio is delivered as one chunk the
    /// moment it's generated, so a consumer starts hearing the first sentence (~2 s in)
    /// while the rest is still being made. `onChunk` returning `false` stops before the
    /// next sentence — nothing to latch, the loop is ours.
    public func synthesizeStreaming(text: String, voice: String?, language: String?,
                                    onChunk: @escaping @Sendable (SynthesizedSpeechChunk) -> Bool) async throws {
        try validate(text: text, voice: voice, language: language)
        let reference = try resolvedReference(voice)
        guard let manager else { throw TtsEngineError.notPrepared }

        let promptText = try await promptTranscript(for: reference)
        let sentences = SentenceChunker.sentences(in: text)
        guard !sentences.isEmpty else { throw TtsEngineError.emptyText }

        let started = Date()
        var totalSamples = 0
        for sentence in sentences {
            let samples = try await synthesizeChunk(sentence, reference: reference,
                                                    promptText: promptText, manager: manager)
            totalSamples += samples.count
            guard onChunk(SynthesizedSpeechChunk(samples: samples,
                                                 sampleRate: LuxTtsConstants.outputSampleRate)) else {
                Logger.tts.info("LuxTTS synthesis cancelled by the consumer")
                return
            }
        }
        guard totalSamples > 0 else {
            throw TtsEngineError.synthesisFailed("the model produced no audio")
        }
        let audioSeconds = Double(totalSamples) / Double(LuxTtsConstants.outputSampleRate)
        Logger.tts.info("""
            Cloned \(audioSeconds, format: .fixed(precision: 2), privacy: .public)s of speech \
            in \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s \
            (voice \(reference.id, privacy: .public), \(sentences.count, privacy: .public) chunks)
            """)
    }

    /// One generation call, split-and-retried when the sentence overflows the port's fixed
    /// shape buckets. Recursion bottoms out when a chunk can't be split further; the model's
    /// own too-long error then surfaces honestly.
    private func synthesizeChunk(_ chunk: String, reference: CloningVoiceProfile.Reference,
                                 promptText: String, manager: LuxTtsManager) async throws -> [Float] {
        do {
            let result = try await manager.synthesize(
                text: chunk, promptAudio: reference.audioURL, promptText: promptText)
            return result.samples
        } catch let error as LuxTtsError {
            if case .inputTooLong = error, let (first, second) = SentenceChunker.halves(of: chunk) {
                let firstSamples = try await synthesizeChunk(first, reference: reference,
                                                             promptText: promptText, manager: manager)
                let secondSamples = try await synthesizeChunk(second, reference: reference,
                                                              promptText: promptText, manager: manager)
                return firstSamples + secondSamples
            }
            throw TtsEngineError.synthesisFailed(humanReadable(error))
        } catch {
            throw TtsEngineError.synthesisFailed(humanReadable(error))
        }
    }

    // MARK: - Prompt transcript (the 5-second contract)

    /// The transcript matched to the clip's audible 5.0 s window — resident cache, then the
    /// disk cache, then derived by ASR. The disk cache is keyed on the clip's mtime, so
    /// re-cutting a reference re-derives and an unchanged clip pays ASR exactly once ever.
    private func promptTranscript(for reference: CloningVoiceProfile.Reference) async throws -> String {
        if let cached = promptTexts[reference.id] { return cached }

        let clipPath = reference.audioURL.path
        guard let mtime = try? FileManager.default.attributesOfItem(atPath: clipPath)[.modificationDate] as? Date else {
            throw TtsEngineError.synthesisFailed("reference clip missing: \(clipPath)")
        }

        if let stored = readCachedTranscript(voiceID: reference.id),
           stored.clipPath == clipPath, stored.clipMtime == mtime.timeIntervalSince1970 {
            promptTexts[reference.id] = stored.transcript
            return stored.transcript
        }

        let allSamples: [Float]
        do {
            allSamples = try FileIngestService.loadSamples(from: reference.audioURL)
        } catch {
            throw TtsEngineError.synthesisFailed(
                "couldn't load the reference clip \(clipPath): \(humanReadable(error))")
        }
        // ASR sees exactly what the model will hear: the clip cut at the prompt window.
        let window = Array(allSamples.prefix(Int(PromptTranscript.promptWindowSeconds * AudioChunk.sampleRate)))
        let segments: [AsrSegment]
        do {
            segments = try await promptAsr(window)
        } catch {
            throw TtsEngineError.synthesisFailed(
                "couldn't transcribe the reference clip \(clipPath): \(humanReadable(error))")
        }
        let words = segments.compactMap(\.words).flatMap { $0 }
        let transcript = PromptTranscript.matchedText(words: words)
        guard !transcript.isEmpty else {
            throw TtsEngineError.synthesisFailed(
                "no words recognized in the first \(Int(PromptTranscript.promptWindowSeconds))s "
                + "of the reference clip \(clipPath)")
        }

        writeCachedTranscript(CachedTranscript(clipPath: clipPath,
                                               clipMtime: mtime.timeIntervalSince1970,
                                               transcript: transcript),
                              voiceID: reference.id)
        promptTexts[reference.id] = transcript
        Logger.tts.info("""
            Derived the 5s prompt transcript for \(reference.id, privacy: .public): \
            "\(transcript, privacy: .public)"
            """)
        return transcript
    }

    private struct CachedTranscript: Codable {
        let clipPath: String
        let clipMtime: TimeInterval
        let transcript: String
    }

    private var transcriptCacheFolder: URL {
        downloadBase.appendingPathComponent("prompt-transcripts", isDirectory: true)
    }

    private func readCachedTranscript(voiceID: String) -> CachedTranscript? {
        let url = transcriptCacheFolder.appendingPathComponent("\(voiceID).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedTranscript.self, from: data)
    }

    /// Best-effort: a failed cache write costs a re-derivation next cold start, never the note.
    private func writeCachedTranscript(_ cached: CachedTranscript, voiceID: String) {
        do {
            try FileManager.default.createDirectory(at: transcriptCacheFolder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cached)
            try data.write(to: transcriptCacheFolder.appendingPathComponent("\(voiceID).json"))
        } catch {
            Logger.tts.error("Couldn't cache the prompt transcript for \(voiceID, privacy: .public): \(error, privacy: .public)")
        }
    }
}

private func humanReadable(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
