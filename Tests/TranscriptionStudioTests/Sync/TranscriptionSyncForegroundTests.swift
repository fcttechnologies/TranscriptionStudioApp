import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import Testing
@testable import TranscriptionStudio

/// What a foregrounding costs, end to end, through this app's own bootstrap.
///
/// Rung 1 runs unconditionally — it is the one correctness rides on — which is exactly why its cost
/// has to be measured rather than assumed. A foregrounding that pulses a trigger *and* runs a cycle
/// buys two cycles for one event, and the second is invisible from the outside because both cycles
/// are correct: the only trace is a second round trip on every app switch, on every device.
@Suite("Sync — one foregrounding, one cycle")
@MainActor
struct TranscriptionSyncForegroundTests {
    @Test func aForegroundingCostsOneCycleAndOneRoundTrip() async throws {
        let server = FakeSyncServer()
        let transport = CountingTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        defer { device.tearDown() }

        await device.enroll()
        transport.reset()

        device.sync.foregrounded()
        await settle(transport)

        #expect(transport.reads == 1, "a foregrounding is one full cycle: one read of the whole declaration")
        #expect(transport.pushes == 0, "and with an empty outbox, nothing to send")
        #expect(transport.roundTrips == 1)
    }

    /// The pair, three times over: the Realtime rung is dropped on the way to the background and
    /// re-taken on the way back, and a foregrounding after one is still exactly one cycle.
    @Test func eachForegroundingAfterABackgroundIsItsOwnSingleCycle() async throws {
        let server = FakeSyncServer()
        let transport = CountingTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        defer { device.tearDown() }

        await device.enroll()
        transport.reset()

        for _ in 0..<3 {
            device.sync.foregrounded()
            await settle(transport)
            device.sync.backgrounded()
        }

        #expect(transport.reads == 3, "three foregroundings, three reads")
        #expect(transport.roundTrips == 3)
    }

    /// Wait for the wire to go quiet rather than for the first round trip. The cycle this asserts
    /// the absence of would arrive behind the debounce, so the quiet has to outlast that window —
    /// a poll that stopped at the first read would pass whether or not a second cycle followed.
    private func settle(_ transport: CountingTransport, deadline: Duration = .seconds(20)) async {
        let expiry = ContinuousClock.now + deadline
        var quiet = 0
        var last = -1
        while ContinuousClock.now < expiry {
            try? await Task.sleep(for: .milliseconds(100))
            let now = transport.roundTrips
            quiet = now == last ? quiet + 1 : 0
            last = now
            if quiet >= 8, now > 0 { return }
        }
    }
}
