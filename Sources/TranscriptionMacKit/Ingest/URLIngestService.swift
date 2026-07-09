import Foundation
import Synchronization
import TranscriptionKit

/// Locates the yt-dlp / ffmpeg binaries the way the web app's `config.py` did:
/// PATH first, then the common Homebrew/system install locations.
enum ExternalBinaryLocator {
    static func find(_ name: String) -> URL? {
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// yt-dlp + ffmpeg subprocess port of the web app's `pipeline.py download_audio` /
/// `config.py` ffmpeg detection. macOS-only — no yt-dlp/ffmpeg on iOS. Stateless (no
/// actor needed): concurrent jobs run independent subprocesses into their own temp dirs.
public struct URLIngestService: URLAudioDownloading {
    private static let tempRootName = "TranscriptionStudio"

    public init() {}

    /// Wipes leftover per-job temp dirs from previous runs. Call once at app startup
    /// (web-app parity: `cleanup_startup_temp`).
    public static func sweepStartupTemp() {
        let root = tempRoot()
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for item in contents {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private static func tempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(tempRootName, isDirectory: true)
    }

    /// The per-job temp directory a download/extract is isolated under (web-app parity:
    /// job-ID temp isolation — a real directory boundary here instead of a shared-folder
    /// filename prefix, so concurrent jobs never collide).
    static func jobDirectory(for jobID: UUID) -> URL {
        tempRoot().appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    /// Builds the yt-dlp argument list — ported flag-for-flag from the web app's
    /// `pipeline.py download_audio` (format chain, mp3 extraction, isolation, quiet
    /// flags) plus `--newline`/no `--quiet` so progress is parseable.
    static func buildArguments(url: String, outputTemplate: URL, ffmpegDirectory: String?) -> [String] {
        var arguments = [
            // Prefer a real audio-only stream; else an H.264 stream — TikTok's bytevc1/
            // H.265 "best" formats advertise AAC but download video-only, breaking audio
            // extraction; else any best. Ported verbatim from pipeline.py.
            "-f", "bestaudio/best[vcodec^=h264]/best",
            "-x", "--audio-format", "mp3", "--audio-quality", "192K",
            "--no-playlist",
            "--no-cache-dir",
            "--newline",
            "--no-warnings",
            "-o", outputTemplate.path,
        ]
        if let ffmpegDirectory {
            arguments += ["--ffmpeg-location", ffmpegDirectory]
        }
        arguments.append(url)
        return arguments
    }

    /// Downloads audio for `url` and extracts it to mp3, isolated under a per-job
    /// directory (web-app parity: job-ID temp isolation — a real directory boundary here
    /// instead of a shared-folder filename prefix, so concurrent jobs never collide).
    public func downloadAudio(url: String, jobID: UUID,
                              onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        guard let ytDlp = ExternalBinaryLocator.find("yt-dlp") else {
            throw URLIngestError.toolNotFound("yt-dlp")
        }
        // ffmpeg is optional to *locate* explicitly — yt-dlp falls back to PATH-only
        // resolution if we can't find it, matching config.py's `_detect_ffmpeg_location`.
        let ffmpegDirectory = ExternalBinaryLocator.find("ffmpeg")?.deletingLastPathComponent().path

        let jobDir = Self.jobDirectory(for: jobID)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)

        let arguments = Self.buildArguments(url: url,
                                            outputTemplate: jobDir.appendingPathComponent("audio.%(ext)s"),
                                            ffmpegDirectory: ffmpegDirectory)

        try await Self.run(binary: ytDlp, arguments: arguments, onProgress: onProgress)

        let mp3 = jobDir.appendingPathComponent("audio.mp3")
        guard FileManager.default.fileExists(atPath: mp3.path) else {
            throw URLIngestError.outputMissing
        }
        return mp3
    }

    /// Removes a job's temp directory once its audio has been ingested.
    public func cleanup(jobID: UUID) {
        try? FileManager.default.removeItem(at: Self.jobDirectory(for: jobID))
    }

    // MARK: - Subprocess

    private static func run(binary: URL, arguments: [String],
                            onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutParser = LineAccumulator { line in
                if let progress = parseProgress(line: line) {
                    onProgress(progress)
                }
            }
            let stderrTail = Mutex<[String]>([])
            let stderrParser = LineAccumulator { line in
                stderrTail.withLock { lines in
                    lines.append(line)
                    if lines.count > 20 { lines.removeFirst() }
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                stdoutParser.feed(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrParser.feed(handle.availableData)
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = stderrTail.withLock { $0.joined(separator: "\n") }
                    continuation.resume(throwing: URLIngestError.downloadFailed(
                        message.isEmpty ? "yt-dlp exited with status \(proc.terminationStatus)" : message))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: URLIngestError.downloadFailed(error.localizedDescription))
            }
        }
    }

    /// Parses yt-dlp `--newline` progress lines, e.g.
    /// `[download]  45.2% of 3.45MiB at 1.23MiB/s ETA 00:02`.
    static func parseProgress(line: String) -> DownloadProgress? {
        guard line.hasPrefix("[download]"),
              let percentRange = line.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) else {
            return nil
        }
        let percentText = line[percentRange].dropLast() // drop "%"
        guard let percent = Double(percentText) else { return nil }
        let eta: String? = line.range(of: #"ETA \S+"#, options: .regularExpression)
            .map { String(line[$0].dropFirst(4)) }
        return DownloadProgress(fractionCompleted: percent / 100, etaText: eta)
    }
}

/// Thread-safe newline splitter for subprocess output read off a background queue
/// (`Pipe.fileHandleForReading.readabilityHandler` fires on its own dispatch source).
private final class LineAccumulator: Sendable {
    private let buffer = Mutex(Data())
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = buffer.withLock { buf in
            buf.append(data)
            var extracted: [String] = []
            while let range = buf.range(of: Data([0x0A])) {
                extracted.append(String(decoding: buf.subdata(in: buf.startIndex..<range.lowerBound), as: UTF8.self))
                buf.removeSubrange(buf.startIndex..<range.upperBound)
            }
            return extracted
        }
        for line in lines { onLine(line) }
    }
}
