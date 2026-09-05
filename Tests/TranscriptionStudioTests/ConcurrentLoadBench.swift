import FCTCore
import Foundation
import Testing
@testable import TranscriptionStudio

/// The concurrent-load measurement: Parakeet and the Sortformer diarizer sharing this
/// machine's compute at once, versus each alone. Env-gated
/// (`CONCURRENT_BENCH=1`) because it downloads/loads the real models and takes minutes —
/// run it to (re)measure; results print as `[BENCH]` lines and are asserted only loosely
/// (both pipelines must finish and stay faster than realtime).
@Suite("Concurrent ASR + diarization load",
       .enabled(if: ProcessInfo.processInfo.environment["CONCURRENT_BENCH"] == "1"))
struct ConcurrentLoadBench {

    @Test func concurrentVersusIsolated() async throws {
        guard DiarFixtures.exists("two_speakers_long") else {
            Issue.record("TestResources/two_speakers_long.wav missing — run scripts/make-verification-audio.sh")
            return
        }
        let samples = try DiarFixtures.loadSamples("two_speakers_long")
        let audioSeconds = Double(samples.count) / AudioChunk.sampleRate
        print("[BENCH] clip: \(FCTCore.Format.fixed(audioSeconds, decimals: 1))s, \(samples.count) samples")

        let asr = FCTSpeechAsrEngine()
        try await asr.prepare(onProgress: { _ in })
        let diarizer = FCTSpeechDiarizationEngine()
        try await diarizer.prepare(onProgress: { _ in })

        func thermal() -> String { "\(ProcessInfo.processInfo.thermalState.rawValue)" }
        func timeIt<T>(_ operation: () async throws -> T) async rethrows -> (T, TimeInterval) {
            let clock = ContinuousClock(); let start = clock.now
            let value = try await operation()
            return (value, seconds(start.duration(to: clock.now)))
        }

        // Isolated baselines.
        print("[BENCH] thermal before: \(thermal())")
        let (asrAlone, asrAloneTime) = try await timeIt {
            try await asr.transcribe(samples: samples, track: .mixed, wordTimestamps: false)
        }
        print("[BENCH] ASR alone: \(FCTCore.Format.fixed(asrAloneTime, decimals: 2))s"
              + " (RTF \(FCTCore.Format.fixed(asrAloneTime / audioSeconds, decimals: 3)))"
              + " segments=\(asrAlone.count) thermal=\(thermal())")

        let (diarAlone, diarAloneTime) = try await timeIt {
            try await diarizer.diarize(samples: samples)
        }
        print("[BENCH] diarize alone: \(FCTCore.Format.fixed(diarAloneTime, decimals: 2))s"
              + " (RTF \(FCTCore.Format.fixed(diarAloneTime / audioSeconds, decimals: 3)))"
              + " turns=\(diarAlone.turns.count) thermal=\(thermal())")

        // Concurrent run.
        let clock = ContinuousClock(); let start = clock.now
        async let asrTask = timeIt {
            try await asr.transcribe(samples: samples, track: .mixed, wordTimestamps: false)
        }
        async let diarTask = timeIt {
            try await diarizer.diarize(samples: samples)
        }
        let ((asrBoth, asrBothTime), (diarBoth, diarBothTime)) = try await (asrTask, diarTask)
        let wall = seconds(start.duration(to: clock.now))
        print("[BENCH] concurrent: wall \(FCTCore.Format.fixed(wall, decimals: 2))s thermal=\(thermal())")
        print("[BENCH]   ASR   \(FCTCore.Format.fixed(asrBothTime, decimals: 2))s"
              + " (x\(FCTCore.Format.fixed(asrBothTime / max(asrAloneTime, 0.001), decimals: 2)) vs alone)"
              + " segments=\(asrBoth.count)")
        print("[BENCH]   diar  \(FCTCore.Format.fixed(diarBothTime, decimals: 2))s"
              + " (x\(FCTCore.Format.fixed(diarBothTime / max(diarAloneTime, 0.001), decimals: 2)) vs alone)"
              + " turns=\(diarBoth.turns.count)")

        // Loose gates: both must complete and each stays faster than realtime even shared.
        #expect(!asrBoth.isEmpty)
        #expect(!diarBoth.turns.isEmpty)
        #expect(asrBothTime < audioSeconds)
        #expect(diarBothTime < audioSeconds)
    }
}
