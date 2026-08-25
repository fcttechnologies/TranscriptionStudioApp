import Foundation
import Synchronization

/// Headless transcription CLI — the command-line front end to the app's existing
/// pipeline. A URL rides `URLIngestService` (yt-dlp + ffmpeg → mp3); a file path rides
/// `FileIngestService`; both land in `WhisperKitAsrEngine` (download-if-missing model
/// provisioning, then on-device ASR). Transcript goes to stdout (plain text, or `--json`
/// for segments + timestamps); all progress and errors go to stderr. Exit 0 on success,
/// 1 on failure, 2 on a usage error.
@main
struct TranscribeCLI {
    static let usage = """
    usage: transcribe-cli <url-or-file> [--json] [--model <whisperkit-variant>]
                          [--language <code>]
           transcribe-cli --serve [--port <n>] [--idle-timeout <s>] [--preload]
                          [--model <whisperkit-variant>] [--language <code>]
                          [--voice-profile <path>]
           transcribe-cli speak <text> --out <path> [--voice <name>] [--language <name>]
                          [--voice-profile <path>]

    ONE-SHOT (default): transcribe a single URL or file and exit.
      <url-or-file>    An http(s) URL (any yt-dlp-supported source) or a local
                       media file path (\(SupportedMediaExtensions.allowed.sorted().joined(separator: ", "))).
      --json           Structured output: {source, kind, durationSeconds, text, segments[]}.
      --language <c>   Force the spoken language (ISO code, e.g. "en"/"es") instead of
                       Whisper's auto-detect.

    SERVE: run a warm on-device transcription service (drop-in for the old FastAPI app on
           the same :8000 API — POST /api/jobs/start, GET /api/jobs/{id}, POST /api/transcribe/file),
           which also speaks: POST /speak {text, voice?, language?} -> audio/wav, streamed
           (chunked transfer) as the audio is synthesized.
      --serve          Start the HTTP service (holds the models warm across requests).
      --port <n>       Listen port (default: 8000).
      --idle-timeout <s>  Release a model after this many seconds idle, reloading on demand
                       (default: 600 = ~10 min; 0 = never release / stay warm forever). The
                       recognition and synthesis models idle out independently.
      --preload        Load the recognition model at startup for the lowest first-request
                       latency (eager). Synthesis always loads on its first request.

    SPEAK: synthesize speech from text with the on-device model and write it to a file.
      speak <text>     The text to say.
      --out <path>     Where to write the audio — 16-bit mono WAV (required).
      --voice <name>   Preset voice (default: \(TTSKitTtsEngine.defaultVoice)).
                       One of: \(TTSKitTtsEngine.supportedVoices.joined(separator: ", ")).
                       With --voice-profile, also any of the profile's cloned voice ids.
      --language <n>   Spoken language (default: \(TTSKitTtsEngine.defaultLanguage)).
                       One of: \(TTSKitTtsEngine.supportedLanguages.joined(separator: ", ")).
                       The synthesis model downloads on first use (progress on stderr).

    Shared:
      --model <name>   WhisperKit model variant (default: \(WhisperKitAsrEngine.platformDefaultModelName)).
                       Downloaded on first use if missing (progress on stderr).
      --voice-profile <path>  A voice-profile.json naming reference clips for zero-shot
                       voice CLONING (CoreML LuxTTS). Each reference id becomes a voice
                       beside the presets — ask for one by name; no voice still means the
                       preset default. The cloning model (~346 MB) downloads on the first
                       cloned request.
    """

    static func main() async {
        // `speak` is a leading verb, so the one-shot path below (which reads a bare argument as
        // the media to transcribe) is reached on exactly the same inputs it always was.
        if CommandLine.arguments.dropFirst().first == "speak" {
            await runSpeak(arguments: Array(CommandLine.arguments.dropFirst(2)))
            return
        }

        var jsonOutput = false
        var modelName = WhisperKitAsrEngine.platformDefaultModelName
        var forcedLanguage: String?
        var input: String?
        var serve = false
        var port: UInt16 = 8000
        var idleTimeout: TimeInterval = 600
        var preload = false
        var voiceProfilePath: String?

        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--json":
                jsonOutput = true
            case "--model":
                guard let name = arguments.next() else { exitUsage("--model needs a value") }
                modelName = name
            case "--language":
                guard let code = arguments.next() else { exitUsage("--language needs a value") }
                forcedLanguage = code
            case "--serve":
                serve = true
            case "--port":
                guard let value = arguments.next(), let p = UInt16(value) else { exitUsage("--port needs a numeric value") }
                port = p
            case "--idle-timeout":
                guard let value = arguments.next(), let s = TimeInterval(value), s >= 0 else { exitUsage("--idle-timeout needs a non-negative number of seconds") }
                idleTimeout = s
            case "--preload":
                preload = true
            case "--voice-profile":
                guard let path = arguments.next() else { exitUsage("--voice-profile needs a value") }
                voiceProfilePath = path
            case "--help", "-h":
                print(usage)
                exit(0)
            default:
                guard !argument.hasPrefix("-") else { exitUsage("unknown option: \(argument)") }
                guard input == nil else { exitUsage("more than one input given") }
                input = argument
            }
        }

        if serve {
            await runServe(port: port, idleTimeout: idleTimeout, preload: preload,
                           modelName: modelName, forcedLanguage: forcedLanguage,
                           voiceProfilePath: voiceProfilePath)
            return  // runServe never returns on success (blocks on accept); returns only to exit
        }

        guard let input else { exitUsage("no input given") }

        do {
            let result = try await transcribe(input: input, modelName: modelName,
                                              forcedLanguage: forcedLanguage)
            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
            } else {
                print(result.text)
            }
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Serve

    /// Run the warm transcription HTTP service until killed. Builds the warm engines (the
    /// recognition one optionally preloaded), starts the idle reaper (a no-op at idle-timeout 0),
    /// and blocks on the accept loop. Never returns on success.
    ///
    /// `--preload` covers recognition only. The 24/7 service exists for the `transcribe` tool, so
    /// that model earns its residency; eagerly loading a ~1 GB synthesis model that a given day
    /// may never ask for would double the resident footprint on a personal machine for nothing.
    /// Synthesis loads on its first `/speak` and then stays warm on the same idle rules.
    static func runServe(port: UInt16, idleTimeout: TimeInterval, preload: Bool,
                         modelName: String, forcedLanguage: String?,
                         voiceProfilePath: String?) async {
        let warm = WarmEngine(modelName: modelName, forcedLanguage: forcedLanguage, idleTimeout: idleTimeout)
        let speech = WarmTTSEngine(idleTimeout: idleTimeout,
                                   makeEngine: makeSpeechEngine(voiceProfilePath: voiceProfilePath,
                                                                warmAsr: warm))

        if preload {
            status("Preloading \(modelName)…")
            do {
                try await warm.ensureLoaded { progress in status("\(progress.phase)…") }
                status("Model ready.")
            } catch {
                fail("preload failed: \(error.localizedDescription)")
            }
        }

        // Idle reaper: release a model once it's been idle past the timeout. Both engines are
        // swept on the same tick but against their own last-used clocks, so either can be
        // resident while the other is reaped. No-op at 0 (warm forever), so only spun up when a
        // positive timeout is set.
        if idleTimeout > 0 {
            Task.detached {
                while true {
                    try? await Task.sleep(for: .seconds(60))
                    await warm.reapIfIdle()
                    await speech.reapIfIdle()
                }
            }
        }

        let server = TranscribeServer(port: port, warm: warm, speech: speech)
        do {
            try server.run()  // blocks forever on accept()
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Synthesis engine factory

    /// The synthesis engine for a serve process or a one-shot speak: preset-only without a
    /// voice profile, the preset/cloning router with one. The profile file is loaded HERE —
    /// eagerly — so a bad profile fails the process at startup with a clear message, never a
    /// first `/speak` days later (`WarmTTSEngine.makeEngine` can't throw).
    ///
    /// The cloner's prompt-matching ASR rides the serve's warm recognition engine when there
    /// is one (same model, same idle clock); a one-shot speak builds its own. Either way the
    /// derived transcript is disk-cached per clip, so the ASR cost is paid once per reference,
    /// not per note.
    static func makeSpeechEngine(voiceProfilePath: String?,
                                 warmAsr: WarmEngine?) -> @Sendable () -> any TtsEngine {
        guard let voiceProfilePath else {
            return { TTSKitTtsEngine() }
        }
        let profileURL = URL(fileURLWithPath: (voiceProfilePath as NSString).expandingTildeInPath)
        let profile: CloningVoiceProfile
        do {
            profile = try CloningVoiceProfile.load(from: profileURL)
        } catch {
            fail(error.localizedDescription)
        }
        status("Voice cloning enabled: \(profile.voiceIDs.joined(separator: ", "))")
        let promptAsr: LuxTtsCloningEngine.PromptAsr
        if let warmAsr {
            promptAsr = { samples in try await warmAsr.transcribeWithWordTimestamps(samples: samples) }
        } else {
            promptAsr = { samples in
                let asr = WhisperKitAsrEngine()
                try await asr.prepare { _ in }
                return try await asr.transcribe(samples: samples, track: .mixed, wordTimestamps: true)
            }
        }
        return {
            VoiceRoutingTtsEngine(
                preset: TTSKitTtsEngine(),
                presetVoices: TTSKitTtsEngine.supportedVoices,
                cloning: LuxTtsCloningEngine(profile: profile, promptAsr: promptAsr),
                cloningVoices: profile.voiceIDs)
        }
    }

    // MARK: - Speak

    /// `transcribe-cli speak <text> --out <path>` — synthesize on-device and write a WAV.
    /// The written path goes to stdout (the one-shot path's transcript-on-stdout discipline);
    /// model download and synthesis progress go to stderr.
    static func runSpeak(arguments: [String]) async {
        var text: String?
        var outputPath: String?
        var voice: String?
        var language: String?
        var voiceProfilePath: String?

        var argumentIterator = arguments.makeIterator()
        while let argument = argumentIterator.next() {
            switch argument {
            case "--out":
                guard let value = argumentIterator.next() else { exitUsage("--out needs a value") }
                outputPath = value
            case "--voice":
                guard let value = argumentIterator.next() else { exitUsage("--voice needs a value") }
                voice = value
            case "--language":
                guard let value = argumentIterator.next() else { exitUsage("--language needs a value") }
                language = value
            case "--voice-profile":
                guard let value = argumentIterator.next() else { exitUsage("--voice-profile needs a value") }
                voiceProfilePath = value
            case "--help", "-h":
                print(usage)
                exit(0)
            default:
                guard !argument.hasPrefix("-") else { exitUsage("unknown option: \(argument)") }
                guard text == nil else { exitUsage("more than one text argument given") }
                text = argument
            }
        }

        guard let text else { exitUsage("speak needs the text to synthesize") }
        guard let outputPath else { exitUsage("speak needs --out <path>") }

        do {
            let engine = makeSpeechEngine(voiceProfilePath: voiceProfilePath, warmAsr: nil)()
            // Fail on a bad voice/language before downloading a gigabyte of weights.
            try engine.validate(text: text, voice: voice, language: language)

            let lastPhase = Mutex("")
            try await engine.prepare { progress in
                let percent = progress.fraction.map { Int($0 * 100) }
                let line = percent.map { "\(progress.phase)… \($0)%" } ?? "\(progress.phase)…"
                // Download ticks are near-continuous; report each phase and each 10% step.
                let key = percent.map { "\(progress.phase)-\($0 / 10)" } ?? progress.phase
                let shouldPrint = lastPhase.withLock { last in
                    guard key != last else { return false }
                    last = key
                    return true
                }
                if shouldPrint { status(line) }
            }

            status("Synthesizing…")
            let speech = try await engine.synthesize(text: text, voice: voice, language: language)
            let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            try speech.wavData().write(to: url)
            status(String(format: "Wrote %.2fs of audio.", speech.duration))
            print(url.path)
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Pipeline

    static func transcribe(input: String, modelName: String,
                           forcedLanguage: String? = nil) async throws -> TranscriptOutput {
        let isURL = URLComponents(string: input).flatMap(\.scheme).map { ["http", "https"].contains($0.lowercased()) } ?? false

        var cleanup: () async -> Void = {}
        do {
            // Ingest: URL → yt-dlp download + mp3 extract; file → direct load.
            let audioFileURL: URL
            if isURL {
                let downloader: any URLAudioDownloading = URLIngestService()
                let jobID = UUID()
                cleanup = { await downloader.cleanup(jobID: jobID) }
                status("Downloading audio…")
                let lastReported = Mutex(-1)
                audioFileURL = try await downloader.downloadAudio(url: input, jobID: jobID) { progress in
                    guard let fraction = progress.fractionCompleted else { return }
                    let percent = Int(fraction * 100)
                    let shouldPrint = lastReported.withLock { last in
                        guard percent >= last + 10 || percent == 100 && last != 100 else { return false }
                        last = percent
                        return true
                    }
                    if shouldPrint {
                        status("Downloading audio… \(percent)%\(progress.etaText.map { " (ETA \($0))" } ?? "")")
                    }
                }
            } else {
                let path = (input as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: path) else {
                    throw CLIError("no such file: \(path)")
                }
                audioFileURL = URL(fileURLWithPath: path)
            }
            let samples = try FileIngestService.loadSamples(from: audioFileURL)
            let duration = Double(samples.count) / AudioChunk.sampleRate

            // ASR: provision the model if needed (progress → stderr), then transcribe.
            let engine = WhisperKitAsrEngine(modelName: modelName, forcedLanguage: forcedLanguage)
            let lastPhase = Mutex("")
            try await engine.prepare { progress in
                let percent = progress.fraction.map { Int($0 * 100) }
                let line = percent.map { "\(progress.phase)… \($0)%" } ?? "\(progress.phase)…"
                let shouldPrint = lastPhase.withLock { last in
                    // Model download ticks are near-continuous; report each phase and 10% steps.
                    let key = percent.map { "\(progress.phase)-\($0 / 10)" } ?? progress.phase
                    guard key != last else { return false }
                    last = key
                    return true
                }
                if shouldPrint { status(line) }
            }

            status("Transcribing \(Int(duration))s of audio…")
            let segments = try await engine.transcribe(samples: samples, track: .mixed, wordTimestamps: false)
            await cleanup()

            return TranscriptOutput(
                source: input,
                kind: isURL ? "url" : "file",
                durationSeconds: duration,
                text: segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                segments: segments.map { TranscriptOutput.Segment(start: $0.start, end: $0.end, text: $0.text) }
            )
        } catch {
            await cleanup()
            throw error
        }
    }

    // MARK: - Output shapes + plumbing

    struct TranscriptOutput: Encodable {
        struct Segment: Encodable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
        }

        let source: String
        let kind: String
        let durationSeconds: TimeInterval
        let text: String
        let segments: [Segment]
    }

    struct CLIError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func status(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("transcribe-cli: " + message + "\n").utf8))
        exit(1)
    }

    static func exitUsage(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("transcribe-cli: " + message + "\n" + usage + "\n").utf8))
        exit(2)
    }
}
