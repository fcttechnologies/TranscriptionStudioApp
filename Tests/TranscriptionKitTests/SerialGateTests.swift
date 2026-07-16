// `SerialGate` (backing `SortformerEngine`'s per-instance serialization) — a plain FIFO async
// gate, independent of Sortformer/the model, so it's fully testable without any artifacts:
// mutual exclusion (no interleaved critical sections, so no lost updates on a shared counter)
// and FIFO hand-off order once a caller is queued.

import Foundation
import Testing
@testable import TranscriptionKit

/// A deliberately racy read-modify-write counter: if two `increment()` calls ever interleave,
/// the final count comes out low. `@unchecked Sendable` — safety is `SerialGate`'s job, not
/// this type's; that's exactly what's under test.
private final class UnsafeCounter: @unchecked Sendable {
    private(set) var value = 0

    func increment() async {
        let old = value
        await Task.yield()   // give a racing caller a chance to interleave, if it can
        value = old + 1
    }
}

/// Records the order `record(_:)` is called in. Only ever called from inside a gate-guarded
/// section in these tests, so no lock of its own is needed — that serialization is the thing
/// under test.
private final class OrderRecorder: @unchecked Sendable {
    private(set) var order: [Int] = []
    func record(_ i: Int) { order.append(i) }
}

@Suite("SerialGate")
struct SerialGateTests {
    @Test func serializesConcurrentOperationsWithNoLostUpdates() async throws {
        let gate = SerialGate()
        let counter = UnsafeCounter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.run { await counter.increment() }
                }
            }
            try await group.waitForAll()
        }

        // If SerialGate let two increments interleave, this would land under 20.
        #expect(counter.value == 20)
    }

    @Test func waitersAreServicedInFIFOEnqueueOrder() async throws {
        let gate = SerialGate()
        let recorder = OrderRecorder()

        // Task 0 grabs the gate immediately and holds it, so every later task queues.
        let first = Task {
            try await gate.run {
                try await Task.sleep(for: .milliseconds(60))
                recorder.record(0)
            }
        }
        try await Task.sleep(for: .milliseconds(10))   // let task 0 win the acquire race

        var queued: [Task<Void, Never>] = []
        for i in 1...3 {
            queued.append(Task {
                await gate.run { recorder.record(i) }
            })
            try await Task.sleep(for: .milliseconds(5))   // stagger enqueue order deterministically
        }

        _ = try await first.value
        for task in queued { await task.value }

        #expect(recorder.order == [0, 1, 2, 3])
    }
}
