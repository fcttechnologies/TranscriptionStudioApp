// `WarmTTSEngine`'s model lifecycle: load once, reuse, release when idle, reload on demand —
// and never load at all for a request that was going to be rejected anyway. Driven by
// `MockTtsEngine` so none of it needs the real ~1 GB weights.

import Foundation
import Testing
@testable import transcribe_cli

@Suite("WarmTTSEngine — model lifecycle")
struct WarmTTSEngineTests {
    /// A model is only loaded on first use — constructing the warm holder loads nothing.
    @Test func startsUnloaded() async {
        let warm = WarmTTSEngine(idleTimeout: 600, makeEngine: { MockTtsEngine() })
        #expect(await warm.isResident == false)
    }

    @Test func loadsOnFirstUseAndIsIdempotentAfter() async throws {
        let engine = MockTtsEngine()
        let warm = WarmTTSEngine(idleTimeout: 600, makeEngine: { engine })

        try await warm.ensureLoaded()
        #expect(await warm.isResident)
        #expect(await engine.prepareCount == 1)

        try await warm.ensureLoaded()
        try await warm.ensureLoaded()
        #expect(await engine.prepareCount == 1)
    }

    @Test func synthesizeLoadsTheModelAndReturnsTheEnginesAudio() async throws {
        let engine = MockTtsEngine(sampleRate: 24_000)
        let warm = WarmTTSEngine(idleTimeout: 600, makeEngine: { engine })

        let speech = try await warm.synthesize(text: "Hello there.", voice: nil, language: nil)
        #expect(await warm.isResident)
        #expect(await engine.prepareCount == 1)
        #expect(speech.sampleRate == 24_000)
        #expect(speech.duration > 0)
    }

    /// The reaper's contract, mirroring `WarmEngine`: 0 means never release.
    @Test func neverReleasesAtIdleTimeoutZero() async throws {
        let warm = WarmTTSEngine(idleTimeout: 0, makeEngine: { MockTtsEngine() })
        try await warm.ensureLoaded()
        try await Task.sleep(for: .milliseconds(100))
        await warm.reapIfIdle()
        #expect(await warm.isResident)
    }

    @Test func releasesOnceIdlePastTheTimeoutAndReloadsOnDemand() async throws {
        let engine = MockTtsEngine()
        let warm = WarmTTSEngine(idleTimeout: 0.05, makeEngine: { engine })

        try await warm.ensureLoaded()
        #expect(await warm.isResident)

        // Not idle long enough yet.
        await warm.reapIfIdle()
        #expect(await warm.isResident)

        try await Task.sleep(for: .milliseconds(300))
        await warm.reapIfIdle()
        #expect(await warm.isResident == false)

        // …and the next request brings it back.
        try await warm.ensureLoaded()
        #expect(await warm.isResident)
    }

    /// Use refreshes the idle clock, so a model in steady use is never reaped out from under a
    /// busy caller.
    @Test func useKeepsTheModelAliveAcrossTheIdleWindow() async throws {
        let warm = WarmTTSEngine(idleTimeout: 0.2, makeEngine: { MockTtsEngine() })
        try await warm.ensureLoaded()

        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(100))
            _ = try await warm.synthesize(text: "Still here.", voice: nil, language: nil)
            await warm.reapIfIdle()
            #expect(await warm.isResident)
        }
    }

    /// The reason validation is a model-free requirement on the seam: a bad request must not
    /// pull a gigabyte of weights into memory before being rejected.
    @Test func rejectsABadRequestWithoutEverLoadingTheModel() async {
        let engine = MockTtsEngine()
        let warm = WarmTTSEngine(idleTimeout: 600, makeEngine: { engine })

        await #expect(throws: TtsEngineError.emptyText) {
            try await warm.synthesize(text: "   ", voice: nil, language: nil)
        }
        await #expect(throws: TtsEngineError.unsupportedVoice("gandalf", supported: MockTtsEngine.supportedVoices)) {
            try await warm.synthesize(text: "Hello.", voice: "gandalf", language: nil)
        }
        await #expect(throws: TtsEngineError.unsupportedLanguage("klingon", supported: MockTtsEngine.supportedLanguages)) {
            try await warm.synthesize(text: "Hello.", voice: nil, language: "klingon")
        }

        #expect(await warm.isResident == false)
        #expect(await engine.prepareCount == 0)
    }
}

@Suite("speakErrorStatus — which failures are the caller's")
struct SpeakErrorStatusTests {
    @Test func requestFailuresAre400() {
        #expect(speakErrorStatus(TtsEngineError.emptyText) == 400)
        #expect(speakErrorStatus(TtsEngineError.unsupportedVoice("x", supported: ["a"])) == 400)
        #expect(speakErrorStatus(TtsEngineError.unsupportedLanguage("x", supported: ["a"])) == 400)
    }

    @Test func engineFailuresAre500() {
        #expect(speakErrorStatus(TtsEngineError.notPrepared) == 500)
        #expect(speakErrorStatus(TtsEngineError.modelDownloadFailed(underlying: "offline")) == 500)
        #expect(speakErrorStatus(TtsEngineError.synthesisFailed("boom")) == 500)
    }

    @Test func anUnrelatedErrorIsTheServersProblem() {
        struct Boom: Error {}
        #expect(speakErrorStatus(Boom()) == 500)
    }
}
