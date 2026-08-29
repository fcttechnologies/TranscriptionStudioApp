import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import Testing
@testable import TranscriptionStudio

/// A wire that fails one pull to arm the backoff and then answers slowly, asking for a second pass
/// from inside the recovering cycle — the way the applier's own save does when a pull lands rows.
///
/// `Task.sleep` throwing `CancellationError` is the whole detector, the same one the debounce suite
/// uses: a pull that is merely slow finishes, and a pull whose enclosing cycle was cancelled does
/// not. The failed pull never reaches the counter, so a non-zero `pullsStarted` is itself the proof
/// that the retry fired at all.
private final class RetryTransport: SyncTransport, @unchecked Sendable {
    private let inner: FakeTransport
    private let trigger: ManualTrigger
    private let lock = NSLock()
    private var _pullsStarted = 0
    private var _pullsCancelled = 0
    private var _failuresRemaining: Int
    private var _askedForAnotherPass = false

    var pullsStarted: Int { lock.withLock { _pullsStarted } }
    var pullsCancelled: Int { lock.withLock { _pullsCancelled } }

    init(server: FakeSyncServer, trigger: ManualTrigger, failuresBeforeSuccess: Int = 1) {
        inner = FakeTransport(server: server)
        self.trigger = trigger
        _failuresRemaining = failuresBeforeSuccess
    }

    func push(schemaVersion: String, records: [PushRecord]) async throws -> [PushVerdict] {
        try await inner.push(schemaVersion: schemaVersion, records: records)
    }

    func pull(schemaVersion: String, table: String, cursor: Int64, pageLimit: Int) async throws -> PullEnvelope {
        let failing = lock.withLock { () -> Bool in
            guard _failuresRemaining > 0 else { return false }
            _failuresRemaining -= 1
            return true
        }
        if failing { throw SyncTransportError.connectivity("no route to host (test)") }

        // Asked for from the wire rather than on a timer, which is what makes the second pass
        // certain: the request lands while the cycle is provably still inside a pull. Once is
        // enough — a request per pull would keep the loop running for as long as the test watched.
        let shouldFire = lock.withLock { () -> Bool in
            _pullsStarted += 1
            guard !_askedForAnotherPass else { return false }
            _askedForAnotherPass = true
            return true
        }
        if shouldFire { trigger.fire() }

        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            lock.withLock { _pullsCancelled += 1 }
            // The raw `CancellationError` is deliberate. Dressing it as `.connectivity` — what
            // `NSURLErrorCancelled` becomes through `PostgRESTTransport`, and so the obvious "more
            // faithful" edit — would put the engine back in `.offline(retryingIn:)` and arm a fresh
            // 1s·2ⁿ backoff inside the quiet window the settle below reads as finished.
            throw error
        }
        return try await inner.pull(
            schemaVersion: schemaVersion, table: table, cursor: cursor, pageLimit: pageLimit
        )
    }
}

/// The backoff retry's one hard rule — the debounce's rule, one layer up.
///
/// `scheduleRetry` is the last statement of `syncNow()`'s `repeat … while syncAgain` body, so when
/// the task running that loop *is* the retry task, the `retryTask?.cancel()` at the top cancels the
/// task currently executing. It sits above the `.offline` guard, so it fires on every result, a
/// success included, and what runs cancelled is the second pass: the staging sweep, the blob drain
/// and the pull, all torn down mid-flight.
///
/// It is the come-back-from-offline path, and this library is the worst place to lose it. The
/// restore here is the fleet's heaviest — sessions, then segments in their hundreds, then speakers
/// and highlights — so a pull that lands rows asks for a second pass nearly every time, and the
/// retry that finally got through cancels that pass on its way out of the first. The debounce suite
/// covers the trigger layer; nothing reached this one.
@Suite("Sync — the retry cancels the wait, never its own cycle")
@MainActor
struct TranscriptionSyncRetryTests {
    @Test func aRetryCycleDoesNotCancelItselfWhenItNeedsASecondPass() async throws {
        let server = FakeSyncServer()
        let trigger = ManualTrigger()
        let transport = RetryTransport(server: server, trigger: trigger)
        let device = try BootstrapDevice(server: server, transport: transport, triggers: [trigger])
        defer { device.tearDown() }

        // Enrolling runs a cycle, and this one fails on the wire: the engine goes
        // `.offline(retryingIn:)` and `scheduleRetry` arms the retry task. A first failure is a 2⁰
        // backoff, so the retry wakes about a second later, onto a wire that now answers.
        await device.enroll()

        try #require(
            await settled(transport),
            "the retry never reached the wire, or the cycles never stopped starting pulls"
        )

        #expect(transport.pullsStarted > 0, "the retry path never reached the transport")
        #expect(
            transport.pullsCancelled == 0,
            """
            \(transport.pullsCancelled) of \(transport.pullsStarted) pulls were cancelled \
            mid-flight. A retry must let go of its handle once past its wait, so the \
            `scheduleRetry` ending its own cycle finds nothing to tear down.
            """
        )
    }

    /// Wait for the retry to reach the wire, and only then for the cycles to stop — two phases, and
    /// they are not interchangeable. Between the failed cycle and the retry the wire is quiet for
    /// the whole backoff, so a stability poll started there reads that gap as quiescence and samples
    /// the counters before the cycle under trial has run at all. A fixed span is worse still: one
    /// calibrated on the broken run expires mid-pull on the green one, where the surviving cycles
    /// live longer and start more pulls, and `tearDown` then deletes the store underneath one of
    /// them — a SwiftData fault that takes the whole run down rather than a failing assertion.
    private func settled(_ transport: RetryTransport, deadline: Duration = .seconds(30)) async -> Bool {
        let expiry = ContinuousClock.now + deadline
        while transport.pullsStarted == 0, ContinuousClock.now < expiry {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard transport.pullsStarted > 0 else { return false }

        var quietSamples = 0
        var last = -1
        while ContinuousClock.now < expiry {
            try? await Task.sleep(for: .milliseconds(150))
            let now = transport.pullsStarted
            quietSamples = now == last ? quietSamples + 1 : 0
            last = now
            if quietSamples >= 8 { return true }
        }
        return false
    }
}
