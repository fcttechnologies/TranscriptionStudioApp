import Foundation
import Testing
@testable import TranscriptionMacKit

@Suite("URLIngestService")
struct URLIngestServiceTests {

    // yt-dlp argument construction: the TikTok-safe format chain, mp3 extraction,
    // isolation flags, and the output template all land in the right order.
    @Test func buildsExpectedYtDlpArguments() {
        let template = URL(fileURLWithPath: "/tmp/TranscriptionStudio/job-1/audio.%(ext)s")
        let args = URLIngestService.buildArguments(url: "https://example.com/video",
                                                    outputTemplate: template,
                                                    ffmpegDirectory: "/opt/homebrew/bin")
        #expect(args == [
            "-f", "bestaudio/best[vcodec^=h264]/best",
            "-x", "--audio-format", "mp3", "--audio-quality", "192K",
            "--no-playlist",
            "--no-cache-dir",
            "--newline",
            "--no-warnings",
            "-o", template.path,
            "--ffmpeg-location", "/opt/homebrew/bin",
            "https://example.com/video",
        ])
    }

    // No ffmpeg location found → yt-dlp falls back to PATH-only resolution, matching
    // config.py's empty-string fallback.
    @Test func omitsFfmpegLocationWhenNotFound() {
        let template = URL(fileURLWithPath: "/tmp/audio.%(ext)s")
        let args = URLIngestService.buildArguments(url: "https://example.com/v", outputTemplate: template,
                                                    ffmpegDirectory: nil)
        #expect(!args.contains("--ffmpeg-location"))
        #expect(args.last == "https://example.com/v")
    }

    // Per-job temp isolation: two jobs never share a directory, and it's namespaced
    // under the app's own temp root.
    @Test func perJobDirectoriesAreIsolated() {
        let jobA = URLIngestService.jobDirectory(for: UUID())
        let jobB = URLIngestService.jobDirectory(for: UUID())
        #expect(jobA != jobB)
        #expect(jobA.path.contains("TranscriptionStudio"))
        #expect(jobA.deletingLastPathComponent() == jobB.deletingLastPathComponent())
    }

    // Startup sweep clears any leftover per-job dirs without touching the temp root itself.
    @Test func startupSweepClearsLeftoverJobDirs() throws {
        let jobID = UUID()
        let jobDir = URLIngestService.jobDirectory(for: jobID)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        try Data("leftover".utf8).write(to: jobDir.appendingPathComponent("audio.mp3"))
        #expect(FileManager.default.fileExists(atPath: jobDir.path))

        URLIngestService.sweepStartupTemp()

        #expect(!FileManager.default.fileExists(atPath: jobDir.path))
    }

    // cleanup(jobID:) removes exactly that job's directory.
    @Test func cleanupRemovesOnlyItsOwnJobDirectory() throws {
        let service = URLIngestService()
        let keepID = UUID()
        let removeID = UUID()
        let keepDir = URLIngestService.jobDirectory(for: keepID)
        let removeDir = URLIngestService.jobDirectory(for: removeID)
        try FileManager.default.createDirectory(at: keepDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removeDir, withIntermediateDirectories: true)

        service.cleanup(jobID: removeID)

        #expect(FileManager.default.fileExists(atPath: keepDir.path))
        #expect(!FileManager.default.fileExists(atPath: removeDir.path))
        try? FileManager.default.removeItem(at: keepDir)
    }

    // Download progress parsing pulls the percentage out of a real yt-dlp --newline line.
    @Test func parsesDownloadProgressLine() throws {
        let line = "[download]  45.2% of ~  3.45MiB at    1.23MiB/s ETA 00:02"
        let progress = try #require(URLIngestService.parseProgress(line: line))
        #expect(abs((progress.fractionCompleted ?? 0) - 0.452) < 0.0001)
        #expect(progress.etaText == "00:02")
    }

    // Non-download lines (postprocessor chatter, etc.) don't parse as progress.
    @Test func ignoresNonDownloadLines() {
        #expect(URLIngestService.parseProgress(line: "[ExtractAudio] Destination: audio.mp3") == nil)
        #expect(URLIngestService.parseProgress(line: "[download] Destination: audio.webm") == nil)
    }
}
