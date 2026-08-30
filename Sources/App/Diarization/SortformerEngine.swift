// SortformerEngine — the `DiarizationEngine` conformance for the NVIDIA Streaming Sortformer
// 4-spk v2 diarizer (CC-BY-4.0) on Core AI.
//
// Builds/loads the graph (opt-in) and forwards to the stateful `SortformerCore` (SortformerCore.swift),
// whose AOSC math lives in SortformerAOSC.swift.
//
// ⚠️ The currently-published model does not specialize on this toolchain — see
// Documentation/SORTFORMER-MODEL.md. The mel frontend, AOSC math, and streaming loop are
// unit-verified independently of the model; the live forward pass lights up once a re-exported
// model loads. SpeakerKit is the shipping default.

import Foundation
import Synchronization

/// A single-permit FIFO async gate: serializes whole async operations above a reentrant core.
///
/// Waiters `await`-suspend (they never block a thread), and the critical section runs in the
/// CALLER's task, so cancellation propagates into a running operation naturally. No lock is held
/// across the `await`, so it cannot deadlock — each enqueued waiter is resumed by exactly one
/// predecessor `release()`, in FIFO order, until the queue drains. (A waiter whose task is
/// cancelled while queued still takes its turn, then exits promptly.)
actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Run `body` only after every previously-enqueued operation has finished.
    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
        // Resumed by a predecessor's release(): ownership is transferred to us (busy stays true).
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }   // hand ownership to the next waiter
    }
}

/// The `DiarizationEngine` conformance: builds/loads the graph (opt-in), forwards to the core.
///
/// Whole `diarize`/`stream` operations are serialized per instance by `gate`: one engine (with its
/// one stateful `SortformerCore`) is reused across concurrent `startTranscription` calls, so two
/// overlapping operations must NOT interleave their `reset()` + streaming loop. The gate makes the
/// second wait for the first to finish rather than corrupt its in-flight AOSC state.
///
/// `@unchecked Sendable` (not plain `Sendable`) because `previewInterval` is a public mutable
/// `var`. The one piece of internal shared mutable state — `core`, reassigned in `prepare()` and
/// read from `diarize()`/`stream()` on possibly-concurrent tasks — is guarded by a `Mutex`, so
/// those accesses are race-free.
final class SortformerEngine: DiarizationEngine, @unchecked Sendable {
    let backendName = "Sortformer (Core AI)"

    private let store: SortformerModelStore
    private let recorder: PipelineRecorder?
    private let sessionID: UUID?
    private let makeGraph: @Sendable (URL) async throws -> GraphRunner
    private let core = Mutex<SortformerCore?>(nil)
    private let gate = SerialGate()

    /// - Parameters:
    ///   - store: artifact locator/verifier.
    ///   - makeGraph: how to build the runtime from the model URL. Defaults to the raw Core AI
    ///     runner; tests inject a fake so the loop runs without the (currently unloadable) model.
    init(store: SortformerModelStore = SortformerModelStore(),
                recorder: PipelineRecorder? = nil,
                sessionID: UUID? = nil,
                makeGraph: (@Sendable (URL) async throws -> GraphRunner)? = nil) {
        self.store = store
        self.recorder = recorder
        self.sessionID = sessionID
        if let makeGraph {
            self.makeGraph = makeGraph
        } else {
            self.makeGraph = { url in
                #if canImport(CoreAI)
                return try await CoreAIGraphRunner(modelURL: url)
                #else
                throw GraphRunnerError.unavailable("CoreAI framework not available on this platform")
                #endif
            }
        }
    }

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        onProgress(EnginePreparationProgress(phase: "Verifying Sortformer artifacts", fraction: nil))
        // Local-first: a re-exported/provisioned model dir is used as-is; else fetch from HF.
        try await store.provision { p in
            onProgress(EnginePreparationProgress(phase: "Downloading \(p.file)", fraction: p.fraction))
        }
        try store.verifyArtifacts()
        onProgress(EnginePreparationProgress(phase: "Loading Sortformer graph", fraction: nil))
        let graph = try await makeGraph(store.modelURL)   // ⚠️ aborts on the current published model
        let mel = SortformerMel(melFilters: try store.loadMelFilters())
        core.withLock { $0 = SortformerCore(graph: graph, mel: mel, recorder: recorder, sessionID: sessionID) }
        onProgress(EnginePreparationProgress(phase: "Sortformer ready", fraction: 1))
    }

    func diarize(samples: [Float]) async throws -> DiarizationResult {
        guard let core = core.withLock({ $0 }) else { throw GraphRunnerError.unavailable("prepare() not called") }
        return try await gate.run { try await core.diarizeFull(samples: samples) }
    }

    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        // Snapshot the guarded state before the Task: `Mutex` is non-copyable and can't be captured.
        let core = core.withLock { $0 }
        let previewInterval = previewInterval
        let gate = gate
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let core else {
                    continuation.finish(throwing: GraphRunnerError.unavailable("prepare() not called"))
                    return
                }
                do {
                    // Serialize the WHOLE session behind the gate so a concurrent op on this engine
                    // can't interleave its reset+loop with ours.
                    try await gate.run {
                        await core.reset()
                        var buffer: [Float] = []
                        var lastPreview: TimeInterval = 0
                        for try await chunk in chunks {
                            buffer.append(contentsOf: chunk.samples)
                            let elapsed = Double(buffer.count) / AudioChunk.sampleRate
                            // Commit whenever a chunk is available; preview on the cadence.
                            if elapsed - lastPreview >= previewInterval {
                                let update = try await core.advance(samples: buffer, isFinal: false)
                                continuation.yield(update)
                                lastPreview = elapsed
                            }
                        }
                        let final = try await core.advance(samples: buffer, isFinal: true)
                        continuation.yield(final)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Preview cadence in seconds (the two-tier design's provisional-label interval).
    var previewInterval: TimeInterval = 3.0
}
