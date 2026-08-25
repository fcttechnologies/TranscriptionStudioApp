import Foundation
import Observation

/// The background-job model, ported from the web app: named steps, an active index, a
/// progress fraction, and a terminal state — but observable natively instead of polled.
@MainActor
@Observable
final class TranscriptionJob: Identifiable {
    enum State: String, Sendable {
        case queued, running, done, error, cancelled
    }

    let id: UUID
    let createdAt: Date
    let title: String
    /// Ordered stage labels shown in the UI (web-app parity: e.g. Download → Extract →
    /// Transcribe → Done). Fixed at creation per job kind.
    let steps: [String]

    private(set) var state: State = .queued
    private(set) var activeStepIndex: Int = 0
    private(set) var stageText: String = "Queued…"
    /// 0...1 across the whole job.
    private(set) var progress: Double = 0
    private(set) var errorMessage: String?
    /// The session this job produced, once done (persisted separately via SwiftData).
    private(set) var resultSessionID: UUID?

    /// Set by the runner so the UI can cancel; cancellation cooperates via Task.
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String, steps: [String]) {
        self.id = UUID()
        self.createdAt = Date()
        self.title = title
        self.steps = steps
    }

    func advance(to stepIndex: Int, stageText: String, progress: Double) {
        state = .running
        self.activeStepIndex = min(max(stepIndex, 0), max(steps.count - 1, 0))
        self.stageText = stageText
        self.progress = min(max(progress, 0), 1)
    }

    func finish(resultSessionID: UUID?) {
        state = .done
        self.resultSessionID = resultSessionID
        stageText = "Done"
        progress = 1
        activeStepIndex = steps.count
    }

    func fail(_ message: String) {
        state = .error
        errorMessage = message
        stageText = "Failed"
        progress = 1
    }

    func cancel() {
        task?.cancel()
        state = .cancelled
        stageText = "Cancelled"
    }
}

/// The live job list the UI observes; completed/failed jobs are retained briefly for
/// review, then swept (web-app parity: retention + cleanup).
@MainActor
@Observable
final class JobStore {
    private(set) var jobs: [TranscriptionJob] = []
    /// Seconds a terminal job stays listed before sweep.
    var retention: TimeInterval = 60 * 60
    /// The periodic sweeper — terminal jobs are otherwise only swept on `add`, so a session
    /// that stops adding jobs would keep finished cards past `retention` indefinitely.
    @ObservationIgnored private var sweepTask: Task<Void, Never>?

    init(sweepInterval: TimeInterval = 60) {
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(sweepInterval))
                guard let self else { return }
                self.sweep()
            }
        }
    }

    func add(_ job: TranscriptionJob) {
        jobs.append(job)
        sweep()
    }

    func remove(_ job: TranscriptionJob) {
        jobs.removeAll { $0.id == job.id }
    }

    /// Remove the finished job that produced a now-deleted session, so its card doesn't
    /// linger in the jobs list past the session it belongs to. A running/queued job has no
    /// `resultSessionID` yet, so it's never matched here.
    func removeJobs(forSessionID sessionID: UUID) {
        jobs.removeAll { $0.resultSessionID == sessionID }
    }

    func sweep(now: Date = Date()) {
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
