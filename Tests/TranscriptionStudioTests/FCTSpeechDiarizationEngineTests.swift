import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("FCTSpeechDiarizationEngine before prepare")
struct FCTSpeechDiarizationEngineTests {
    @Test func diarizeThrowsBeforePrepareIsCalled() async {
        let engine = FCTSpeechDiarizationEngine(modelsDirectory: URL(fileURLWithPath: "/nonexistent"))
        await #expect(throws: AsrEngineError.self) { try await engine.diarize(samples: [Float](repeating: 0, count: 16_000)) }
    }

    @Test func streamFinishesWithAnErrorBeforePrepareIsCalled() async {
        let engine = FCTSpeechDiarizationEngine(modelsDirectory: URL(fileURLWithPath: "/nonexistent"))
        let chunks = AsyncThrowingStream<AudioChunk, Error> { c in c.finish() }
        var failed = false
        do { for try await _ in engine.stream(chunks: chunks) {} } catch { failed = true }
        #expect(failed)
    }

    @Test func prepareRefusesAMissingModelByPath() async {
        let engine = FCTSpeechDiarizationEngine(modelsDirectory: URL(fileURLWithPath: "/nonexistent"))
        await #expect(throws: (any Error).self) { try await engine.prepare { _ in } }
    }
}
