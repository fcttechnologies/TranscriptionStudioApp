import FCTBlobSyncTesting
import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import Testing
@testable import TranscriptionStudio

/// A wire that holds every pull open long enough for a second trigger to land on top of it, and
/// records whether the cycle the pull belonged to was torn down around it.
///
/// `Task.sleep` throwing `CancellationError` is the whole detector: a pull that is merely slow
/// finishes, and a pull whose enclosing cycle was cancelled does not. That is exactly the
/// distinction the field reports as `NSURLErrorCancelled (-999)` on the pull RPC.
///
/// `LaggingTransport` beside it in `BootstrapDevice` serves the same slowness and counts nothing,
/// which is why this one exists rather than a latency argument.
private final class SlowTransport: SyncTransport, @unchecked Sendable {
    private let inner: FakeTransport
    private let lock = NSLock()
    private var _pullsStarted = 0
    private var _pullsCancelled = 0

    var pullsStarted: Int { lock.withLock { _pullsStarted } }
    var pullsCancelled: Int { lock.withLock { _pullsCancelled } }

    init(server: FakeSyncServer) {
        inner = FakeTransport(server: server)
    }

    func push(schemaVersion: String, records: [PushRecord]) async throws -> [PushVerdict] {
        try await inner.push(schemaVersion: schemaVersion, records: records)
    }

    func pull(schemaVersion: String, table: String, cursor: Int64, pageLimit: Int) async throws -> PullEnvelope {
        lock.withLock { _pullsStarted += 1 }
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            lock.withLock { _pullsCancelled += 1 }
            throw error
        }
        return try await inner.pull(
            schemaVersion: schemaVersion, table: table, cursor: cursor, pageLimit: pageLimit
        )
    }
}

/// The debounce's one hard rule.
///
/// Coalescing a burst of triggers into one cycle is right; **cancelling a cycle that has already
/// started is not**, and the two are one line apart. `scheduleDebouncedSync` cancels the previous
/// debounce task, and once that task is past its wait it is already inside `syncNow()` — so the
/// cancellation tears down the HTTP request underneath it instead of the wait it was aimed at.
///
/// It bites hardest where it is least visible: the first pull after a sign-in. The applier's own
/// save fires `LocalSaveTrigger`, so **every page a restore lands schedules a debounce that kills
/// the restore that produced it**. It converges only because each attempt applies a little more,
/// and on a slower link or a larger library it can outlive the restore's own timeout and report
/// that the account could not be reached — for an account that answered every request.
///
/// This library is the fleet's heaviest restore (sessions, segments, speakers, highlights), so the
/// cycle here is long and the window a trigger can land in is wide.
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

        // The shape a restore produces on its own: one save per applied page, spaced so each
        // trigger lands while the cycle the previous one started is still inside a pull.
        for _ in 0..<6 {
            trigger.fire()
            try await Task.sleep(for: .milliseconds(300))
        }
        try await settle(transport)

        #expect(transport.pullsStarted > 0, "the harness never reached the transport")
        #expect(
            transport.pullsCancelled == 0,
            """
            \(transport.pullsCancelled) of \(transport.pullsStarted) pulls were cancelled \
            mid-flight. A later trigger must coalesce into the running cycle, never tear it down.
            """
        )
    }

    /// Wait for the wire to go quiet, rather than for a fixed span. A cycle's length scales with
    /// the schema's table count, and this app has the fleet's widest schema — a duration that
    /// settles a smaller app leaves a pull in flight here, and `tearDown` then deletes the store
    /// underneath it, which is a SwiftData fault that takes the whole run down rather than a
    /// failing assertion.
    private func settle(_ transport: SlowTransport, deadline: Duration = .seconds(30)) async throws {
        let step = Duration.milliseconds(100)
        var elapsed = Duration.zero
        var last = -1
        var quietSamples = 0
        while elapsed < deadline {
            let started = transport.pullsStarted
            quietSamples = started == last ? quietSamples + 1 : 0
            last = started
            if quietSamples >= 8 { return }
            try await Task.sleep(for: step)
            elapsed += step
        }
    }
}
