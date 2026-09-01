import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import Testing
@testable import TranscriptionStudio

/// A wire that fails one read to arm the backoff and then answers slowly, asking for a second pass
/// from inside the recovering cycle — the way a Realtime nudge or a foregrounding does when it
/// lands while a cycle is running.
///
/// `Task.sleep` throwing `CancellationError` is the whole detector, the same one the debounce suite
/// uses: a read that is merely slow finishes, and a read whose enclosing cycle was cancelled does
/// not. The failed read never reaches the counter, so a non-zero `readsStarted` is itself the proof
/// that the retry fired at all.
private final class RetryTransport: SyncTransport, @unchecked Sendable {
    private let inner: FakeTransport
    private let lock = NSLock()
    private var _readsStarted = 0
    private var _readsCancelled = 0
    private var _failuresRemaining: Int
    private var _asked = false
    private var _askForAnotherPass: (@Sendable () -> Void)?

    var readsStarted: Int { lock.withLock { _readsStarted } }
    var readsCancelled: Int { lock.withLock { _readsCancelled } }

    init(server: FakeSyncServer, failuresBeforeSuccess: Int = 1) {
        inner = FakeTransport(server: server)
        _failuresRemaining = failuresBeforeSuccess
    }

    /// What the wire asks for once it is inside the recovering cycle. Installed after the device
    /// exists, because what it asks is the device's own bootstrap for another pass.
    func askForAnotherPass(_ body: @escaping @Sendable () -> Void) {
        lock.withLock { _askForAnotherPass = body }
    }

    func push(schemaVersion: String, records: [PushRecord]) async throws -> [PushVerdict] {
        try await inner.push(schemaVersion: schemaVersion, records: records)
    }

    func pullAll(
        schemaVersion: String,
        cursors: [String: Int64],
        rowBudget: Int
    ) async throws -> PullAllEnvelope {
        let failing = lock.withLock { () -> Bool in
            guard _failuresRemaining > 0 else { return false }
            _failuresRemaining -= 1
            return true
        }
        if failing { throw SyncTransportError.connectivity("no route to host (test)") }

        // Asked for from the wire rather than on a timer, which is what makes the second pass
        // certain: the request lands while the cycle is provably still inside a read. Once is
        // enough — a request per read would keep the loop running for as long as the test watched.
        let ask = lock.withLock { () -> (@Sendable () -> Void)? in
            _readsStarted += 1
            guard !_asked else { return nil }
            _asked = true
            return _askForAnotherPass
        }
        ask?()

        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            lock.withLock { _readsCancelled += 1 }
            // The raw `CancellationError` is deliberate. Dressing it as `.connectivity` — what
            // `NSURLErrorCancelled` becomes through `PostgRESTTransport`, and so the obvious "more
            // faithful" edit — would put the engine back in `.offline(retryingIn:)` and arm a fresh
            // 1s·2ⁿ backoff inside the quiet window the settle below reads as finished.
            throw error
        }
        return try await inner.pullAll(
            schemaVersion: schemaVersion, cursors: cursors, rowBudget: rowBudget
        )
    }
}

/// The backoff retry's one hard rule — the debounce's rule, one layer up.
///
/// `scheduleRetry` is the last statement of the cycle loop's body, so when the task running that
/// loop *is* the retry task, a cancel aimed at the retry handle cancels the task currently
/// executing. It fires on every result, a success included, and what runs cancelled is the second
/// pass: the staging sweep, the blob drain and the read, all torn down mid-flight.
///
/// It is the come-back-from-offline path, and this library is the worst place to lose it. The
/// restore here is the fleet's heaviest — sessions, then segments in their hundreds, then speakers
/// and highlights — so a cycle is long, and the requests that ask for a second pass from inside one
/// (a Realtime nudge, a foregrounding, a network path coming back) land in it. The debounce suite
/// covers the trigger layer; nothing reached this one.
@Suite("Sync — the retry cancels the wait, never its own cycle")
@MainActor
struct TranscriptionSyncRetryTests {
    @Test func aRetryCycleDoesNotCancelItselfWhenItNeedsASecondPass() async throws {
        let server = FakeSyncServer()
        let transport = RetryTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        defer { device.tearDown() }

        // A full second pass, asked for from inside the recovering cycle: the nudge's own shape,
        // and the one that has a read to tear down.
        transport.askForAnotherPass { [sync = device.sync] in
            Task { @MainActor in await sync.syncNow(.full) }
        }

        // Enrolling runs a cycle, and this one fails on the wire: the engine goes
        // `.offline(retryingIn:)` and `scheduleRetry` arms the retry task. A first failure is a 2⁰
        // backoff, so the retry wakes about a second later, onto a wire that now answers.
        await device.enroll()

        try #require(
            await settled(transport),
            "the retry never reached the wire, or the cycles never stopped starting reads"
        )

        // The retry's own read, and the second pass's. One alone means the pass this is about
        // never ran, and the assertion below would hold for a cycle that had nothing to cancel.
        #expect(transport.readsStarted > 1,
                "the retry's second pass never reached the wire (\(transport.readsStarted) reads)")
        #expect(
            transport.readsCancelled == 0,
            """
            \(transport.readsCancelled) of \(transport.readsStarted) reads were cancelled \
            mid-flight. A retry must let go of its handle once past its wait, so the \
            `scheduleRetry` ending its own cycle finds nothing to tear down.
            """
        )
    }

    /// Wait for the retry to reach the wire, and only then for the cycles to stop — two phases, and
    /// they are not interchangeable. Between the failed cycle and the retry the wire is quiet for
    /// the whole backoff, so a stability poll started there reads that gap as quiescence and samples
    /// the counters before the cycle under trial has run at all. A fixed span is worse still: one
    /// calibrated on the broken run expires mid-read on the green one, where the surviving cycles
    /// live longer and start more reads, and `tearDown` then deletes the store underneath one of
    /// them — a SwiftData fault that takes the whole run down rather than a failing assertion.
    private func settled(_ transport: RetryTransport, deadline: Duration = .seconds(30)) async -> Bool {
        let expiry = ContinuousClock.now + deadline
        while transport.readsStarted == 0, ContinuousClock.now < expiry {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard transport.readsStarted > 0 else { return false }

        var quietSamples = 0
        var last = -1
        while ContinuousClock.now < expiry {
            try? await Task.sleep(for: .milliseconds(150))
            let now = transport.readsStarted
            quietSamples = now == last ? quietSamples + 1 : 0
            last = now
            if quietSamples >= 8 { return true }
        }
        return false
    }
}
