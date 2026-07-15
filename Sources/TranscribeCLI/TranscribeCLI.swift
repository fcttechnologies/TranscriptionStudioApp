import Foundation
import Synchronization
import TranscriptionKit
import TranscriptionMacKit

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

    ONE-SHOT (default): transcribe a single URL or file and exit.
      <url-or-file>    An http(s) URL (any yt-dlp-supported source) or a local
                       media file path (\(SupportedMediaExtensions.allowed.sorted().joined(separator: ", "))).
      --json           Structured output: {source, kind, durationSeconds, text, segments[]}.
      --language <c>   Force the spoken language (ISO code, e.g. "en"/"es") instead of
                       Whisper's auto-detect.

    SERVE: run a warm on-device transcription service (drop-in for the old FastAPI app on
           the same :8000 API — POST /api/jobs/start, GET /api/jobs/{id}, POST /api/transcribe/file).
      --serve          Start the HTTP service (holds the model warm across requests).
      --port <n>       Listen port (default: 8000).
      --idle-timeout <s>  Release the model after this many seconds idle, reloading on demand
                       (default: 600 = ~10 min; 0 = never release / stay warm forever).
      --preload        Load the model at startup for the lowest first-request latency (eager).

    Shared:
      --model <name>   WhisperKit model variant (default: \(WhisperKitAsrEngine.platformDefaultModelName)).
                       Downloaded on first use if missing (progress on stderr).
    """

    static func main() async {
        var jsonOutput = false
        var modelName = WhisperKitAsrEngine.platformDefaultModelName
        var forcedLanguage: String?
        var input: String?
        var serve = false
        var port: UInt16 = 8000
        var idleTimeout: TimeInterval = 600
        var preload = false

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
                           modelName: modelName, forcedLanguage: forcedLanguage)
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

    /// Run the warm transcription HTTP service until killed. Builds one warm engine (optionally
    /// preloaded), starts the idle reaper (a no-op at idle-timeout 0), and blocks on the accept
    /// loop. Never returns on success.
    static func runServe(port: UInt16, idleTimeout: TimeInterval, preload: Bool,
                         modelName: String, forcedLanguage: String?) async {
        let warm = WarmEngine(modelName: modelName, forcedLanguage: forcedLanguage, idleTimeout: idleTimeout)

        if preload {
            status("Preloading \(modelName)…")
            do {
                try await warm.ensureLoaded { progress in status("\(progress.phase)…") }
                status("Model ready.")
            } catch {
                fail("preload failed: \(error.localizedDescription)")
            }
        }

        // Idle reaper: release the model once it's been idle past the timeout. No-op at 0 (warm
        // forever), so only spun up when a positive timeout is set.
        if idleTimeout > 0 {
            Task.detached {
                while true {
                    try? await Task.sleep(for: .seconds(60))
                    await warm.reapIfIdle()
                }
            }
        }

        let server = TranscribeServer(port: port, warm: warm)
        do {
            try server.run()  // blocks forever on accept()
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
