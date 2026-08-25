import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import BackgroundTasks
#endif

/// Runs a file/URL transcription job so it survives the app being backgrounded mid-run.
///
/// The gap this closes: only live-mic recording had background cover (the `audio`
/// `UIBackgroundMode`); a file/link transcription job — WhisperKit ASR + diarization, all GPU/ANE
/// work — had none, so backgrounding the app mid-job left it open to suspension. On iOS this now
/// wraps the run in a `BGContinuedProcessingTask` (iOS 26+): the system keeps the job running when
/// the app leaves the foreground (including background GPU access on supported devices) and shows
/// its own Live Activity — title, live stage subtitle, progress bar, and a Cancel the user can tap
/// — driven from the job's existing progress model. macOS has no such suspension limit, so there
/// it's a plain passthrough. If the OS declines the request, it falls back to a bounded
/// `beginBackgroundTask` assertion so short jobs still finish.
enum BackgroundExecution {
    /// Run `work` as `job`'s cancellable task, with platform-appropriate background cover.
    /// Sets `job.task` (on macOS immediately; on iOS once the system starts the continued task).
    /// `title` is the label the system Live Activity shows while the job runs in the background.
    @MainActor
    static func run(job: TranscriptionJob, title: String, _ work: @escaping @MainActor () async -> Void) {
        #if os(iOS)
        ContinuedTranscriptionTask.shared.submit(job: job, title: title, work: work)
        #else
        job.task = Task { @MainActor in await work() }
        #endif
    }
}

/// Pure progress-bridge math — how a `TranscriptionJob`'s 0…1 fraction and lifecycle state map
/// onto the `BGContinuedProcessingTask`'s `Progress`. Kept free of any task/UI type so it's unit
/// testable without a running background task or simulator.
enum JobProgressBridge {
    /// The task `Progress`'s total unit count — the job reports a 0…1 fraction, so a 100-unit
    /// scale reads directly as a whole-number percentage in the system UI.
    static let totalUnitCount: Int64 = 100

    /// The `completedUnitCount` for a job fraction, clamped to 0…`totalUnitCount`.
    static func completedUnitCount(forFraction fraction: Double) -> Int64 {
        let clamped = min(max(fraction, 0), 1)
        return Int64((clamped * Double(totalUnitCount)).rounded())
    }

    /// Whether a job state is terminal — the signal to stop mirroring progress and report the
    /// task complete.
    static func isTerminal(_ state: TranscriptionJob.State) -> Bool {
        switch state {
        case .done, .error, .cancelled: true
        case .queued, .running: false
        }
    }
}

#if os(iOS)
/// Drives file/URL transcription jobs through `BGContinuedProcessingTask` so they keep running
/// when the app is backgrounded. One shared coordinator owns the single wildcard task
/// registration and mirrors each job's progress into its task's `Progress` + Live Activity.
@MainActor
final class ContinuedTranscriptionTask {
    static let shared = ContinuedTranscriptionTask()

    /// The wildcard task identifier (`<bundle-id>.transcription.*`) — registered once, matching
    /// the `BGTaskSchedulerPermittedIdentifiers` entry in the app's Info.plist. Each submitted job
    /// gets a concrete identifier under it (`…​.transcription.<job-uuid>`).
    private static let identifierPrefix = "\(Bundle.main.bundleIdentifier ?? "com.fcttechnologies.TranscriptionStudio").transcription"
    private static var wildcardIdentifier: String { "\(identifierPrefix).*" }
    private static func identifier(for job: TranscriptionJob) -> String { "\(identifierPrefix).\(job.id.uuidString)" }

    private struct PendingRun {
        let job: TranscriptionJob
        let title: String
        let work: @MainActor () async -> Void
    }

    private var didRegister = false
    /// Submitted jobs awaiting the system's launch handler, keyed by concrete identifier.
    private var pending: [String: PendingRun] = [:]
    /// Jobs currently executing under a live task, so a system-side Cancel can reach them.
    private var running: [String: TranscriptionJob] = [:]

    private init() {}

    /// Submit `job`'s `work` as a continued background task. Falls back to a bounded background
    /// assertion if the OS declines the request (e.g. too many concurrent tasks).
    func submit(job: TranscriptionJob, title: String, work: @escaping @MainActor () async -> Void) {
        registerIfNeeded()

        let identifier = Self.identifier(for: job)
        pending[identifier] = PendingRun(job: job, title: title, work: work)
        let subtitle = job.stageText

        // Submit off the main thread — `submitTaskRequest` must not be called from the main
        // thread (it may block), and its completion is delivered on an arbitrary queue. The
        // request is built here (off-main) from Sendable values so nothing non-Sendable crosses.
        Task.detached { [self] in
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            // Queue behind other work rather than fail if the system can't start immediately — a
            // transcription is worth waiting a moment for.
            request.strategy = .queue
            // Keep GPU access alive in the background on devices that support it (WhisperKit /
            // diarization run on the GPU + Neural Engine); requires the Background GPU Access
            // entitlement. ANE work continues regardless; this specifically covers the GPU.
            if BGTaskScheduler.supportedResources.contains(.gpu) {
                request.requiredResources = .gpu
            }
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } catch {
                // The OS declined — run the work anyway under a bounded assertion so short/medium
                // jobs still complete; only very long jobs risk suspension in this fallback.
                await self.handleSubmitFailure(identifier: identifier, title: title)
            }
        }
    }

    /// The OS rejected the continued-task submission — pull the pending run and finish it under a
    /// bounded background assertion instead.
    private func handleSubmitFailure(identifier: String, title: String) {
        guard let run = pending.removeValue(forKey: identifier) else { return }
        run.job.task = BackgroundAssertion.run(title, run.work)
    }

    /// Register the single wildcard launch handler. Continued-processing handlers may be
    /// registered lazily (unlike other `BGTask`s), so this happens on first submit; the guard
    /// makes sure it happens exactly once (a second registration of the same identifier is fatal).
    private func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true
        // Run the launch handler on the main queue so it can adopt MainActor isolation to touch
        // the job model and the (non-Sendable) task without crossing an actor boundary.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.wildcardIdentifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated {
                Self.shared.begin(task)
            }
        }
    }

    /// The system started the task: launch the work and mirror progress until it finishes.
    private func begin(_ task: BGContinuedProcessingTask) {
        let identifier = task.identifier
        guard let run = pending.removeValue(forKey: identifier) else {
            task.setTaskCompleted(success: false)
            return
        }
        // Cancelled in the window between submit and launch — don't start.
        guard !JobProgressBridge.isTerminal(run.job.state) else {
            task.setTaskCompleted(success: run.job.state == .done)
            return
        }

        // A system-side Cancel expires the task; route it to the job's cooperative cancel.
        task.expirationHandler = {
            Task { @MainActor in Self.shared.expire(identifier: identifier) }
        }

        let workTask = Task { @MainActor in await run.work() }
        run.job.task = workTask
        running[identifier] = run.job

        Task { @MainActor in
            task.progress.totalUnitCount = JobProgressBridge.totalUnitCount
            // Mirror the job's progress + stage text into the task (and thus its Live Activity)
            // roughly once a second — accurate progress is what lets the system tell a running
            // job from a stuck one.
            while true {
                task.progress.completedUnitCount = JobProgressBridge.completedUnitCount(forFraction: run.job.progress)
                task.updateTitle(run.title, subtitle: run.job.stageText)
                if JobProgressBridge.isTerminal(run.job.state) { break }
                try? await Task.sleep(for: .seconds(1))
            }
            await workTask.value
            self.running[identifier] = nil
            task.setTaskCompleted(success: run.job.state == .done)
        }
    }

    /// Handle a system-side cancellation (the user tapped Cancel in the Live Activity). Routes to
    /// the job's cooperative cancel, which both cancels the work task and flips the job to
    /// `.cancelled` (so it doesn't surface as an error).
    private func expire(identifier: String) {
        if let run = pending.removeValue(forKey: identifier) {
            run.job.cancel()
            return
        }
        running[identifier]?.cancel()
    }
}

/// A bounded `UIApplication` background-task assertion — the fallback path when the OS declines a
/// continued-processing request. iOS grants a few minutes here (enough for short/medium jobs); the
/// expiration handler ends the assertion cleanly so the app is never terminated for overrunning.
@MainActor
private enum BackgroundAssertion {
    static func run(_ name: String, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            let token = Token()
            token.begin(name)
            await work()
            token.end()
        }
    }

    @MainActor
    private final class Token {
        private var id: UIBackgroundTaskIdentifier = .invalid
        func begin(_ name: String) {
            id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
        }
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
#endif
