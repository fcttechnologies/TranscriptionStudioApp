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

      <url-or-file>   An http(s) URL (any yt-dlp-supported source) or a local
                      media file path (\(SupportedMediaExtensions.allowed.sorted().joined(separator: ", "))).
      --json          Structured output: {source, kind, durationSeconds, text, segments[]}.
      --model <name>  WhisperKit model variant (default: \(WhisperKitAsrEngine.platformDefaultModelName)).
                      Downloaded on first use if missing (progress on stderr).
    """

    static func main() async {
        var jsonOutput = false
        var modelName = WhisperKitAsrEngine.platformDefaultModelName
        var input: String?

        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--json":
                jsonOutput = true
            case "--model":
                guard let name = arguments.next() else { exitUsage("--model needs a value") }
                modelName = name
            case "--help", "-h":
                print(usage)
                exit(0)
            default:
                guard !argument.hasPrefix("-") else { exitUsage("unknown option: \(argument)") }
                guard input == nil else { exitUsage("more than one input given") }
                input = argument
            }
        }
        guard let input else { exitUsage("no input given") }

        do {
            let result = try await transcribe(input: input, modelName: modelName)
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

    // MARK: - Pipeline

    static func transcribe(input: String, modelName: String) async throws -> TranscriptOutput {
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
            let engine = WhisperKitAsrEngine(modelName: modelName)
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
