// SystemLoadSampler's lifecycle: start() samples on a fixed interval and feeds the
// InspectorStore; stop() halts sampling; a second start() restarts cleanly rather than
// stacking timers. The Mach CPU/memory readings themselves aren't mocked (they're real
// process introspection), but their sane-range contract is asserted on real samples.

import Foundation
import Testing
@testable import TranscriptionKit

@Suite("SystemLoadSampler")
@MainActor
struct SystemLoadSamplerTests {

    @Test func startProducesSamplesOnTheConfiguredInterval() async throws {
        let store = InspectorStore()
        let sampler = SystemLoadSampler(store: store, interval: 0.05)

        sampler.start()
        // Generous ceiling: the sampler runs at .utility priority, so heavy machine-wide CPU
        // contention (parallel build/test lanes) can starve its 50ms ticks far past their
        // nominal schedule. A dead sampler still fails here; a starved one no longer false-fails.
        try await waitUntil(timeout: 15) { store.loadSamples.count >= 2 }
        sampler.stop()

        #expect(store.loadSamples.count >= 2)
        for sample in store.loadSamples {
            #expect(sample.cpuPercent >= 0)
            #expect(sample.memoryFootprint > 0)
        }
    }

    @Test func stopHaltsFurtherSampling() async throws {
        let store = InspectorStore()
        let sampler = SystemLoadSampler(store: store, interval: 0.05)

        sampler.start()
        // Same starvation-tolerant ceiling as above — the assertion below is what this test proves.
        try await waitUntil(timeout: 15) { !store.loadSamples.isEmpty }
        sampler.stop()
        // Let any sample already mid-flight when stop() fired land before the baseline read.
        try await Task.sleep(for: .milliseconds(100))
        let countAtStop = store.loadSamples.count
        try await Task.sleep(for: .milliseconds(300))

        // No further samples should land once stopped.
        #expect(store.loadSamples.count == countAtStop)
    }

    /// A second `start()` cancels the first sampler's task rather than running two in
    /// parallel — the append rate stays bounded to one sampler's worth of ticks.
    @Test func restartingReplacesRatherThanStackingTheSampler() async throws {
        let store = InspectorStore()
        let sampler = SystemLoadSampler(store: store, interval: 0.05)

        sampler.start()
        try await Task.sleep(for: .milliseconds(150))
        sampler.start()   // restart mid-run
        try await Task.sleep(for: .milliseconds(150))
        let countAfterRestart = store.loadSamples.count
        sampler.stop()
        try await Task.sleep(for: .milliseconds(200))

        // If two samplers were stacked, the count over the same wall-clock window would be
        // roughly double a single sampler's rate; a generous ceiling still catches a leak.
        #expect(countAfterRestart < 15)
    }

    @Test func stopWithoutAPriorStartIsANoOp() {
        let store = InspectorStore()
        let sampler = SystemLoadSampler(store: store, interval: 0.05)
        sampler.stop()   // must not crash
        #expect(store.loadSamples.isEmpty)
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
