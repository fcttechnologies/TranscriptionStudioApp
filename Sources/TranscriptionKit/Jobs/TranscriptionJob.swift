import Foundation
import Observation

/// The background-job model, ported from the web app: named steps, an active index, a
/// progress fraction, and a terminal state — but observable natively instead of polled.
@MainActor
@Observable
public final class TranscriptionJob: Identifiable {
    public enum State: String, Sendable {
        case queued, running, done, error, cancelled
    }

    public let id: UUID
    public let createdAt: Date
    public let title: String
    /// Ordered stage labels shown in the UI (web-app parity: e.g. Download → Extract →
    /// Transcribe → Done). Fixed at creation per job kind.
    public let steps: [String]

    public private(set) var state: State = .queued
    public private(set) var activeStepIndex: Int = 0
    public private(set) var stageText: String = "Queued…"
    /// 0...1 across the whole job.
    public private(set) var progress: Double = 0
    public private(set) var errorMessage: String?
    /// The session this job produced, once done (persisted separately via SwiftData).
    public private(set) var resultSessionID: UUID?

    /// Set by the runner so the UI can cancel; cancellation cooperates via Task.
    @ObservationIgnored public var task: Task<Void, Never>?

    public init(title: String, steps: [String]) {
        self.id = UUID()
        self.createdAt = Date()
        self.title = title
        self.steps = steps
    }

    public func advance(to stepIndex: Int, stageText: String, progress: Double) {
        state = .running
        self.activeStepIndex = min(max(stepIndex, 0), max(steps.count - 1, 0))
        self.stageText = stageText
        self.progress = min(max(progress, 0), 1)
    }

    public func finish(resultSessionID: UUID?) {
        state = .done
        self.resultSessionID = resultSessionID
        stageText = "Done"
        progress = 1
        activeStepIndex = steps.count
    }

    public func fail(_ message: String) {
        state = .error
        errorMessage = message
        stageText = "Failed"
        progress = 1
    }

    public func cancel() {
        task?.cancel()
        state = .cancelled
        stageText = "Cancelled"
    }
}

/// The live job list the UI observes; completed/failed jobs are retained briefly for
/// review, then swept (web-app parity: retention + cleanup).
@MainActor
@Observable
public final class JobStore {
    public private(set) var jobs: [TranscriptionJob] = []
    /// Seconds a terminal job stays listed before sweep.
    public var retention: TimeInterval = 60 * 60

    public init() {}

    public func add(_ job: TranscriptionJob) {
        jobs.append(job)
        sweep()
    }

    public func remove(_ job: TranscriptionJob) {
        jobs.removeAll { $0.id == job.id }
    }

    public func sweep(now: Date = Date()) {
        jobs.removeAll { job in
            switch job.state {
            case .done, .error, .cancelled:
                now.timeIntervalSince(job.createdAt) > retention
            case .queued, .running:
                false
            }
        }
    }
}
