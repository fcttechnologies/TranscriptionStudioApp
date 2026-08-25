// Diagnostic/error paths through the real Sortformer streaming loop that `SortformerLoopTests`
// doesn't reach because it never wires a `PipelineRecorder` and its `FakeGraphRunner` never
// fails: the `advance()` debug event (only recorded `if let recorder`), `engineForward`'s
// `missingOutput` guard when a graph returns an incomplete result, and `SortformerEngine.stream`'s
// catch when the core throws mid-session. Gated the same way as `SortformerLoopTests` — the
// neural forward pass is still faked, but `prepare()` verifies real local artifacts + loads the
// real mel filterbank, so these only run where that's provisioned.

import Foundation
import Testing
@testable import TranscriptionStudio

/// A `FakeGraphRunner` whose `run(_:)` can be told to omit an output or throw outright, to
/// exercise `SortformerCore`'s error paths without a real model.
private final class FaultyGraphRunner: GraphRunner, @unchecked Sendable {
    let inputNames = ["chunk_mel", "spkcache", "valid"]
    let outputNames = ["preds", "chunk_pe"]
    enum Fault { case omitOutputs, throwOnCall(after: Int) }
    private let fault: Fault
    private(set) var callCount = 0

    init(fault: Fault) { self.fault = fault }

    func run(_ inputs: [String: GraphTensor]) async throws -> [String: GraphTensor] {
        let call = callCount; callCount += 1
        switch fault {
        case .omitOutputs:
            return [:]   // neither "preds" nor "chunk_pe" present
        case .throwOnCall(let after):
            if call >= after { throw GraphRunnerError.unavailable("forced test failure") }
            let S = SortformerConfig.nSpk, E = SortformerConfig.emb
            let T = SortformerConfig.tDim, PE = SortformerConfig.peMax
            return [
                "preds": GraphTensor(values: [Float](repeating: 0.02, count: T * S), shape: [1, T, S]),
                "chunk_pe": GraphTensor(values: [Float](repeating: 0.01, count: PE * E), shape: [1, PE, E]),
            ]
        }
    }
}

@Suite("SortformerCore — diagnostics + error paths (real artifacts, faked graph)", .serialized)
@MainActor
struct SortformerCoreDiagnosticsTests {
    private static func toneSamples(seconds: Double) -> [Float] {
        let n = Int(seconds * AudioChunk.sampleRate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = 0.05 * Float(sin(2 * .pi * 200 * Double(i) / AudioChunk.sampleRate)) }
        return out
    }

    @Test("advance() records a debug event through a wired PipelineRecorder",
          .enabled(if: SortformerModelStore().artifactsPresent))
    func advanceRecordsADebugEventWhenARecorderIsWired() async throws {
        let store = InspectorStore()
        let sessionID = UUID()
        let recorder = PipelineRecorder(store: store)
        let engine = SortformerEngine(recorder: recorder, sessionID: sessionID,
                                      makeGraph: { _ in FakeGraphRunner() })
        try await engine.prepare { _ in }

        let (chunks, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        let all = Self.toneSamples(seconds: 5)
        let per = Int(0.5 * AudioChunk.sampleRate)
        var i = 0
        var t = 0.0
        while i + per <= all.count {
            continuation.yield(AudioChunk(track: .mixed, samples: Array(all[i..<i + per]), startTime: t))
            t += 0.5; i += per
        }
        continuation.finish()

        engine.previewInterval = 1.0
        for try await _ in engine.stream(chunks: chunks) {}

        await Task.yield()
        await Task.yield()
        #expect(store.events.contains {
            $0.sessionID == sessionID && $0.level == .debug && $0.message == "advance"
        })
    }

    @Test("a graph that omits its outputs surfaces GraphRunnerError.missingOutput",
          .enabled(if: SortformerModelStore().artifactsPresent))
    func missingGraphOutputsSurfaceAsMissingOutput() async throws {
        let engine = SortformerEngine(makeGraph: { _ in FaultyGraphRunner(fault: .omitOutputs) })
        try await engine.prepare { _ in }

        await #expect(throws: GraphRunnerError.self) {
            _ = try await engine.diarize(samples: Self.toneSamples(seconds: 15))
        }
    }

    @Test("a graph failure mid-stream terminates the AsyncThrowingStream with that error",
          .enabled(if: SortformerModelStore().artifactsPresent))
    func aGraphFailureMidStreamPropagatesThroughTheAsyncStream() async throws {
        let engine = SortformerEngine(makeGraph: { _ in FaultyGraphRunner(fault: .throwOnCall(after: 0)) })
        try await engine.prepare { _ in }

        let (chunks, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        let all = Self.toneSamples(seconds: 15)   // one full 15s commit chunk -> one forward call
        continuation.yield(AudioChunk(track: .mixed, samples: all, startTime: 0))
        continuation.finish()

        do {
            for try await _ in engine.stream(chunks: chunks) {}
            Issue.record("expected the stream to throw after the forced graph failure")
        } catch is GraphRunnerError {
            // expected — SortformerEngine.stream's catch surfaced the core's thrown error.
        } catch {
            Issue.record("expected GraphRunnerError, got \(error)")
        }
    }
}
