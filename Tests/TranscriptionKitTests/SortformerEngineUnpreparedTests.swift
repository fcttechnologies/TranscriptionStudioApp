// `SortformerEngine`'s "not prepared yet" gates on `diarize`/`stream` — pure wiring, no model
// artifacts or CoreAI needed at all (an engine with no `prepare()` call has a nil `core`, so both
// entry points fail fast). `SortformerLoopTests.swift` only ever exercises the prepared path.

import Foundation
import Testing
@testable import TranscriptionKit

@Suite("SortformerEngine — before prepare()")
struct SortformerEngineUnpreparedTests {
    @Test func diarizeThrowsUnavailableBeforePrepareIsCalled() async {
        let engine = SortformerEngine(makeGraph: { _ in FakeGraphRunner() })
        await #expect(throws: GraphRunnerError.self) {
            _ = try await engine.diarize(samples: [0, 0, 0])
        }
    }

    @Test func streamFinishesWithUnavailableBeforePrepareIsCalled() async {
        let engine = SortformerEngine(makeGraph: { _ in FakeGraphRunner() })
        let (chunks, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        continuation.finish()

        do {
            for try await _ in engine.stream(chunks: chunks) {
                Issue.record("expected no updates before prepare()")
            }
            Issue.record("expected the stream to throw")
        } catch is GraphRunnerError {
            // expected
        } catch {
            Issue.record("expected GraphRunnerError, got \(error)")
        }
    }
}
