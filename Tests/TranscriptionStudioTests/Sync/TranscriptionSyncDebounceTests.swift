import FCTBlobSyncTesting
import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import Testing
@testable import TranscriptionStudio

/// A wire that holds every round trip open long enough for a second trigger to land on top of it,
/// and records whether the cycle the call belonged to was torn down around it.
///
/// `Task.sleep` throwing `CancellationError` is the whole detector: a call that is merely slow
/// finishes, and one whose enclosing cycle was cancelled does not. That is exactly the distinction
/// the field reports as `NSURLErrorCancelled (-999)` on the RPC.
///
/// Both calls rather than the read alone: a trigger asks for a **push** cycle, so the round trip a
/// trigger's own cycle makes is the push, and watching only the read would leave the trigger path
/// with no detector at all.
///
/// `LaggingTransport` beside it in `BootstrapDevice` serves the same slowness and counts nothing,
/// which is why this one exists rather than a latency argument.
private final class SlowTransport: SyncTransport, @unchecked Sendable {
    private let inner: FakeTransport
    private let lock = NSLock()
    private var _callsStarted = 0
    private var _callsCancelled = 0

    var callsStarted: Int { lock.withLock { _callsStarted } }
    var callsCancelled: Int { lock.withLock { _callsCancelled } }

    init(server: FakeSyncServer) {
        inner = FakeTransport(server: server)
    }

    func push(schemaVersion: String, records: [PushRecord]) async throws -> [PushVerdict] {
        try await hold()
        return try await inner.push(schemaVersion: schemaVersion, records: records)
    }

    func pullAll(
        schemaVersion: String,
        cursors: [String: Int64],
        rowBudget: Int
    ) async throws -> PullAllEnvelope {
        try await hold()
        return try await inner.pullAll(
            schemaVersion: schemaVersion, cursors: cursors, rowBudget: rowBudget
        )
    }

    /// The round trip, held open wide enough for the next trigger to land inside it.
    private func hold() async throws {
        lock.withLock { _callsStarted += 1 }
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            lock.withLock { _callsCancelled += 1 }
            throw error
        }
    }
}

/// The debounce's one hard rule, through this app's own bootstrap.
///
/// Coalescing a burst of triggers into one cycle is right; **cancelling a cycle that has already
/// started is not**, and the two are one line apart: a debounce task past its wait is no longer a
/// wait but the cycle itself, so a cancellation aimed at the wait tears down the round trip
/// underneath it. `SyncScheduler` owns that rule and releases the handle before the run begins;
/// what this asserts is that this app's composition still rides it — over this app's own schema,
/// engine and staging sweep, which is where a hand-rolled cancel would come back.
///
/// It bites hardest where it is least visible: a burst of edits landing while a long cycle runs.
/// This library is the fleet's heaviest restore (sessions, segments, speakers, highlights), so the
/// cycle here is long and the window a trigger can land in is wide — and a torn-down cycle reports
/// that the account could not be reached, for an account that answered every request.
@Suite("Sync — the debounce cancels the wait, never a running cycle")
@MainActor
struct TranscriptionSyncDebounceTests {
    @Test func aTriggerArrivingMidCycleDoesNotCancelTheCycleInFlight() async throws {
        let server = FakeSyncServer()
        let trigger = ManualTrigger()
        let transport = SlowTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport, triggers: [trigger])
        defer { device.tearDown() }

        await device.enroll()

        // The shape a burst of edits produces: one save, the trigger it fires, and the next one
        // landing while the cycle the previous one started is still inside a round trip. Each
        // iteration writes real work, because a trigger asks for a **push** cycle and a push cycle
        // with an empty outbox never reaches the wire at all.
        for index in 0..<6 {
            try device.recordSession(title: "Edit \(index)", audio: nil)
            trigger.fire()
            try await Task.sleep(for: .milliseconds(300))
        }
        try await settle(transport)

        // More than the enrolment's own read, or the triggers bought no cycles and there was
        // nothing here for a later one to tear down.
        #expect(transport.callsStarted > 1,
                "the trigger path never reached the wire (\(transport.callsStarted) round trips)")
        #expect(
            transport.callsCancelled == 0,
            """
            \(transport.callsCancelled) of \(transport.callsStarted) round trips were cancelled \
            mid-flight. A later trigger must coalesce into the running cycle, never tear it down.
            """
        )
    }

    /// Wait for the wire to go quiet, rather than for a fixed span. A cycle here carries a staging
    /// sweep, a blob drain and two held-open round trips — a duration that settles a smaller app
    /// leaves a call in flight, and `tearDown` then deletes the store underneath it, which is a
    /// SwiftData fault that takes the whole run down rather than a failing assertion.
    private func settle(_ transport: SlowTransport, deadline: Duration = .seconds(30)) async throws {
        let step = Duration.milliseconds(100)
        var elapsed = Duration.zero
        var last = -1
        var quietSamples = 0
        while elapsed < deadline {
            let started = transport.callsStarted
            quietSamples = started == last ? quietSamples + 1 : 0
            last = started
            if quietSamples >= 8 { return }
            try await Task.sleep(for: step)
            elapsed += step
        }
    }
}
