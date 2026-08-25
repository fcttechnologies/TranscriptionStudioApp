import AppIntents
import Foundation

/// The failure surfaced to Siri/Shortcuts when a tracked transcription job ends in `.error`,
/// carrying the job's own message so the spoken/displayed dialog matches what the app shows.
struct TranscriptionJobFailure: LocalizedError, CustomLocalizedStringResourceConvertible {
    let message: String
    var errorDescription: String? { message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// Follows a live `TranscriptionJob` to its terminal state for the long-running transcribe
/// intents: it mirrors the job's stage/percentage into the intent's system `Progress` (so Siri,
/// Shortcuts, and a Live Activity show a real progress bar), and translates the terminal state
/// into an intent result — the produced session id on success, a thrown error on failure, and a
/// `CancellationError` if the job was cancelled out from under it.
///
/// The intent drives cancellation the other way: when the system cancels the intent, the polling
/// task is cancelled, `Task.checkCancellation()` throws here, and the intent's `onCancel` calls
/// `job.cancel()` — so this only needs to *observe* the cancelled state, not initiate it.
enum TranscribeJobTracking {
    /// Poll interval while a job runs. Short enough that the reported progress and the spoken
    /// result feel live, long enough not to spin the main actor.
    private static let pollInterval: Duration = .milliseconds(300)

    /// Await the job's terminal state, reporting progress into `progress`.
    /// - Returns: the produced session id (may be `nil` only in the degenerate done-without-id case).
    /// - Throws: `TranscriptionJobFailure` if the job failed, `CancellationError` if it (or this
    ///   task) was cancelled.
    static func awaitCompletion(of job: TranscriptionJob, reporting progress: Progress) async throws -> UUID? {
        progress.totalUnitCount = 100
        while true {
            try Task.checkCancellation()
            let snapshot = await MainActor.run { JobSnapshot(job) }
            progress.completedUnitCount = Int64((snapshot.progress * 100).rounded())
            progress.localizedDescription = "Transcribing"
            if !snapshot.stage.isEmpty { progress.localizedAdditionalDescription = snapshot.stage }

            switch snapshot.state {
            case .done:
                return snapshot.resultSessionID
            case .error:
                throw TranscriptionJobFailure(message: snapshot.errorMessage ?? "Transcription failed.")
            case .cancelled:
                throw CancellationError()
            case .queued, .running:
                try await Task.sleep(for: pollInterval)
            }
        }
    }

    /// A Sendable snapshot of the (main-actor, non-Sendable) job, read in one hop so the polling
    /// loop never touches the observable model off the main actor.
    private struct JobSnapshot: Sendable {
        let state: TranscriptionJob.State
        let progress: Double
        let stage: String
        let resultSessionID: UUID?
        let errorMessage: String?

        @MainActor init(_ job: TranscriptionJob) {
            state = job.state
            progress = job.progress
            stage = job.stageText
            resultSessionID = job.resultSessionID
            errorMessage = job.errorMessage
        }
    }
}
