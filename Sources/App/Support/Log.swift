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

    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    nonisolated static let ingest = Logger(subsystem: subsystem, category: "ingest")
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    nonisolated static let asr = Logger(subsystem: subsystem, category: "asr")
    nonisolated static let tts = Logger(subsystem: subsystem, category: "tts")
    nonisolated static let diarization = Logger(subsystem: subsystem, category: "diarization")
    nonisolated static let fusion = Logger(subsystem: subsystem, category: "fusion")
    nonisolated static let jobs = Logger(subsystem: subsystem, category: "jobs")
    nonisolated static let persistence = Logger(subsystem: subsystem, category: "persistence")
    nonisolated static let inspector = Logger(subsystem: subsystem, category: "inspector")
    nonisolated static let models = Logger(subsystem: subsystem, category: "models")
    /// MetricKit production diagnostics (daily metric reports + crash/hang/hitch/launch/memory
    /// events from the field). Metrics only — never transcript content.
    nonisolated static let metrics = Logger(subsystem: subsystem, category: "metrics")
    nonisolated static let backgroundAssets = Logger(subsystem: subsystem, category: "background-assets")
}
