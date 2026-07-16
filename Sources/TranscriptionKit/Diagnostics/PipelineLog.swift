import Foundation
import OSLog

/// Every stage of every pipeline, named. The inspector groups and times by these.
public enum PipelineStage: String, Sendable, Codable, CaseIterable {
    case download        // yt-dlp fetch (Mac URL ingest)
    case extract         // ffmpeg audio extraction
    case ingest          // file load + conversion to 16k mono f32
    case capture         // live audio capture (mic / system)
    case mel             // Sortformer mel frontend
    case asr             // WhisperKit inference (file or streaming window)
    case diarizePreview  // Sortformer stateless preview pass (partial chunk)
    case diarizeCommit   // Sortformer committed chunk (AOSC state advanced)
    case fusion          // speaker × text attribution
    case persistence     // SwiftData writes
    case system          // load samples, lifecycle
}

public enum PipelineEventLevel: String, Sendable, Codable {
    case debug, info, warning, error
}

/// One structured, timestamped pipeline event. Everything the in-app inspector shows is
/// built from these; they also mirror to OSLog (metrics public, content never logged).
public struct PipelineEvent: Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let sessionID: UUID?
    public let stage: PipelineStage
    public let level: PipelineEventLevel
    public let message: String
    /// Wall-clock duration of the operation this event closes, if it times one.
    public let duration: TimeInterval?
    /// Small, structured, *non-personal* details (counts, shapes, rates, thermal states).
    public let metadata: [String: String]

    public init(sessionID: UUID? = nil,
                stage: PipelineStage,
                level: PipelineEventLevel = .info,
                message: String,
                duration: TimeInterval? = nil,
                metadata: [String: String] = [:]) {
        self.id = UUID()
        self.date = Date()
        self.sessionID = sessionID
        self.stage = stage
        self.level = level
        self.message = message
        self.duration = duration
        self.metadata = metadata
    }
}

/// The one seam every pipeline component logs through: mirrors each event to OSLog and
/// forwards it to the main-actor `InspectorStore`. Inject one per app (or a fresh one per
/// test); components hold it as a plain `let`.
public final class PipelineRecorder: Sendable {
    private let store: InspectorStore?
    /// Additive MetricKit bridge: each recorded event's stage is reported as an app state so a
    /// production hang/hitch/crash is attributed to the pipeline stage it happened during. Nil
    /// in tests/previews and the mock `AppModel`; the live `AppModel` injects the shared reporter.
    private let stateReporter: (any PipelineStateReporting)?

    public init(store: InspectorStore?, stateReporter: (any PipelineStateReporting)? = nil) {
        self.store = store
        self.stateReporter = stateReporter
    }

    public func record(_ event: PipelineEvent) {
        let logger = Self.logger(for: event.stage)
        let durationText = event.duration.map { String(format: " (%.1fms)", $0 * 1000) } ?? ""
        switch event.level {
        case .debug:
            logger.debug("[\(event.stage.rawValue, privacy: .public)] \(event.message, privacy: .public)\(durationText, privacy: .public)")
        case .info:
            logger.info("[\(event.stage.rawValue, privacy: .public)] \(event.message, privacy: .public)\(durationText, privacy: .public)")
        case .warning:
            logger.warning("[\(event.stage.rawValue, privacy: .public)] \(event.message, privacy: .public)\(durationText, privacy: .public)")
        case .error:
            logger.error("[\(event.stage.rawValue, privacy: .public)] \(event.message, privacy: .public)\(durationText, privacy: .public)")
        }
        if let store {
            Task { @MainActor in
                store.append(event)
            }
        }
        // Mirror the stage as a MetricKit state (deduped inside the reporter). Ambient stages
        // map to nil and are skipped so they don't clobber the state a concurrent hang belongs to.
        stateReporter?.report(stage: event.stage)
    }

    /// Convenience: time an async operation and record its close with the duration attached.
    public func time<T>(_ stage: PipelineStage,
                        sessionID: UUID? = nil,
                        _ message: String,
                        metadata: [String: String] = [:],
                        operation: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await operation()
        let elapsed = start.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        record(PipelineEvent(sessionID: sessionID, stage: stage, message: message,
                             duration: seconds, metadata: metadata))
        return result
    }

    private static func logger(for stage: PipelineStage) -> Logger {
        switch stage {
        case .download, .extract, .ingest: .ingest
        case .capture: .capture
        case .mel, .diarizePreview, .diarizeCommit: .diarization
        case .asr: .asr
        case .fusion: .fusion
        case .persistence: .persistence
        case .system: .app
        }
    }
}
