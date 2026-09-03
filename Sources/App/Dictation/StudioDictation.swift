import FCTDictation
import Foundation
import Observation

/// The state a dictation is in, for the surface that shows it.
enum DictationPhase: Equatable, Sendable {
    case idle
    /// Installing whatever the chosen engine needs — Apple's locale assets, or a downloaded
    /// model's own files. `detail` is a log-shaped phase name, not a sentence for the screen.
    case preparing(detail: String, fraction: Double?)
    case recording
    /// Transcribing, running any passes, and cleaning up.
    case finishing
    case finished
    case failed(String)
}

/// What went wrong in a way the person needs told.
enum DictationError: Error, CustomLocalizedStringResourceConvertible {
    case cancelled

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .cancelled: "Dictation was cancelled."
        }
    }
}

/// The live state of one dictation, and the "Done" affordance the intent waits on.
///
/// `FCTDictation`'s `DictationRun` owns the sequence — record, transcribe, pass, clean, store,
/// copy — and this owns the part that is the app's: which phase to show, and the suspension
/// between `begin()` and `finish()` where the person is actually speaking. The intent cannot own
/// that wait, because the thing that ends it is a button in this process.
///
/// One dictation at a time. A second `begin()` while one is live is refused rather than queued:
/// there is one microphone and one surface, and a queued dictation would record a sentence the
/// person thought they were saying into the first one.
@MainActor
@Observable
final class StudioDictation {

    /// The container the recording and the finished result cross processes through. Declared on
    /// every target that dictates; `DictationStore` throws when it is missing rather than falling
    /// back to a private directory the app process could not read.
    nonisolated static let appGroupID = "group.com.fcttechnologies.TranscriptionStudio"

    /// Where a finished dictation is opened. It rides the app's one registered scheme — the HOST
    /// is what separates a dictation hand-off from a share-ingest ping, so no second URL type is
    /// declared for it. Only the id crosses; the words stay in the container.
    nonisolated static let route = DictationResultRoute(scheme: IngestURLScheme.scheme, host: "dictation")!

    private(set) var phase: DictationPhase = .idle
    /// The finished dictation, whether it arrived from this process's own run or was read back
    /// out of the App Group container by the URL an intent handed the system.
    private(set) var result: DictationResult?

    @ObservationIgnored private var run: DictationRun?
    @ObservationIgnored private var doneContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var isDoneRequested = false
    @ObservationIgnored private var isCancelled = false

    var isBusy: Bool {
        switch phase {
        case .idle, .finished, .failed: false
        case .preparing, .recording, .finishing: true
        }
    }

    var isRecording: Bool { phase == .recording }

    /// Assemble the run, prepare the engine, and start recording. Throws whatever the assembly,
    /// the engine or the recorder threw — a missing App Group, a declined microphone, a
    /// transcriber this device does not carry — so the failure reaches the caller rather than
    /// leaving a surface waiting on audio nothing is capturing. The phase records it either way,
    /// which is what a control-started dictation (no caller to throw to) shows.
    func begin(makeRun: @MainActor () throws -> DictationRun) async throws {
        guard !isBusy else { return }
        result = nil
        isDoneRequested = false
        isCancelled = false
        phase = .preparing(detail: "preparing", fraction: nil)
        let run: DictationRun
        do {
            run = try makeRun()
        } catch {
            phase = .failed(String(describing: error))
            throw error
        }
        do {
            try await run.prepareEngine { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .preparing = self.phase else { return }
                    self.phase = .preparing(detail: progress.phase, fraction: progress.fraction)
                }
            }
            try await run.begin()
        } catch {
            phase = .failed(String(describing: error))
            throw error
        }
        self.run = run
        phase = .recording
    }

    /// Suspend until the person taps Done or Cancel. Returns immediately when one of them has
    /// already been tapped, which is the ordering an intent cannot control: the person can finish
    /// a two-word dictation before the intent reaches this line.
    func waitForDone() async {
        guard !isDoneRequested else { return }
        await withCheckedContinuation { continuation in
            doneContinuation = continuation
        }
    }

    /// The Done button.
    func markDone() {
        finishWaiting()
    }

    /// The Cancel button: stop, keep nothing, and let whoever is waiting know it was refused.
    func cancel() {
        isCancelled = true
        finishWaiting()
    }

    private func finishWaiting() {
        guard !isDoneRequested else { return }
        isDoneRequested = true
        doneContinuation?.resume()
        doneContinuation = nil
    }

    /// Stop recording and run the rest of the sequence. Throws ``DictationError/cancelled`` when
    /// the person cancelled — the recorder is still stopped and the audio still discarded, because
    /// a cancelled dictation must not leave the microphone open or the bytes on disk.
    @discardableResult
    func finish(vocabulary: DictationVocabulary) async throws -> DictationHandoff {
        guard let run else { throw DictationError.cancelled }
        self.run = nil
        phase = .finishing
        do {
            let handoff = try await run.finish(vocabulary: vocabulary)
            guard !isCancelled else {
                phase = .idle
                throw DictationError.cancelled
            }
            result = handoff.result
            phase = .finished
            return handoff
        } catch let error as DictationError {
            throw error
        } catch {
            phase = .failed(String(describing: error))
            throw error
        }
    }

    /// Show a result that finished somewhere else — the App Group read behind the hand-off URL.
    func present(_ result: DictationResult) {
        self.result = result
        phase = .finished
    }

    /// Back to nothing, for a surface being dismissed.
    func reset() {
        guard !isBusy else { return }
        result = nil
        phase = .idle
    }
}
