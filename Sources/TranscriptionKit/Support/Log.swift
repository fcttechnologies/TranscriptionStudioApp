import Foundation
import OSLog

/// One `Logger` per subsystem category. Never `print`.
///
/// Privacy discipline: never log raw transcript text, audio content, or file
/// names that could carry personal data — use `privacy: .private` for any
/// interpolated value that isn't a metric or an enum.
extension Logger {
    private nonisolated static let subsystem =
        Bundle.main.bundleIdentifier ?? "com.fcttechnologies.TranscriptionStudio"

    public nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    public nonisolated static let ingest = Logger(subsystem: subsystem, category: "ingest")
    public nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    public nonisolated static let asr = Logger(subsystem: subsystem, category: "asr")
    public nonisolated static let diarization = Logger(subsystem: subsystem, category: "diarization")
    public nonisolated static let fusion = Logger(subsystem: subsystem, category: "fusion")
    public nonisolated static let jobs = Logger(subsystem: subsystem, category: "jobs")
    public nonisolated static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public nonisolated static let inspector = Logger(subsystem: subsystem, category: "inspector")
    public nonisolated static let models = Logger(subsystem: subsystem, category: "models")
}
