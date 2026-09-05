import Foundation
import Synchronization
import Testing
@testable import TranscriptionStudio

@Suite("FCTSpeechDiarizationEngine before prepare")
struct FCTSpeechDiarizationEngineTests {
    private static let missing = URL(fileURLWithPath: "/nonexistent")
    private static let noInstall: SpeechModelInstaller = { _, _ in }

    @Test func diarizeThrowsBeforePrepareIsCalled() async {
        let engine = FCTSpeechDiarizationEngine(root: Self.missing, install: Self.noInstall)
        await #expect(throws: AsrEngineError.self) { try await engine.diarize(samples: [Float](repeating: 0, count: 16_000)) }
    }

    @Test func streamFinishesWithAnErrorBeforePrepareIsCalled() async {
        let engine = FCTSpeechDiarizationEngine(root: Self.missing, install: Self.noInstall)
        let chunks = AsyncThrowingStream<AudioChunk, Error> { c in c.finish() }
        var failed = false
        do { for try await _ in engine.stream(chunks: chunks) {} } catch { failed = true }
        #expect(failed)
    }

    @Test func prepareRefusesAMissingModelByPath() async {
        let engine = FCTSpeechDiarizationEngine(root: Self.missing, install: Self.noInstall)
        await #expect(throws: (any Error).self) { try await engine.prepare { _ in } }
    }

    // The store's install runs before the load, and its failure is the engine's failure.
    @Test func prepareInstallsTheModelFirstAndSurfacesItsFailure() async {
        struct Offline: Error {}
        let asked = Mutex<[SpeechModel]>([])
        let engine = FCTSpeechDiarizationEngine(root: Self.missing) { model, _ in
            asked.withLock { $0.append(model) }
            throw Offline()
        }
        await #expect(throws: Offline.self) { try await engine.prepare { _ in } }
        #expect(asked.withLock { $0 } == [.sortformer])
    }
}
