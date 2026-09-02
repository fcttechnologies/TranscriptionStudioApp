import FCTBlobSyncTesting
import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import SwiftData
import Testing
@testable import TranscriptionStudio

/// What a `PresenceHeartbeat` beat actually costs on the wire.
///
/// The Mac's presence beacon writes one `MacPresence` row a minute and saves. `ModelContext.didSave`
/// is process-wide, so `LocalSaveTrigger` fires on it like any other write and the debounce
/// collapses into a cycle the device gains nothing from: the only row it has to send is the row the
/// beat is already sending itself.
///
/// The cost was previously derived by reading that call graph. These tests measure it instead,
/// because a derived number is the kind that turns out to have counted a loop that pages or a
/// branch that no longer runs.
@Suite("Presence heartbeat — what a beat costs on the wire")
@MainActor
struct PresenceSyncCostTests {

    /// The instrument first, against an answer already known: the read path asks for the whole
    /// declaration in one call, so an idle cycle that costs anything other than one round trip —
    /// or asks about anything other than the schema's eleven tables — means the counter is wrong
    /// before any claim rests on it.
    @Test func anIdleCycleCostsOneReadForTheWholeDeclaration() async throws {
        let server = FakeSyncServer()
        let transport = CountingTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        await device.enroll()
        await device.sync.syncNow(.full)

        transport.reset()
        await device.sync.syncNow(.full)

        // One call carrying all eleven cursors, and NO push: the engine skips the push entirely when
        // the outbox is empty. That last part is why a cost derived from the call graph missed
        // that a dirty presence row adds the push back.
        let declared = Set(TranscriptionSyncSchema.schema.tables.map(\.name))
        #expect(declared.count == 11, "this app's nine tables plus the account fragment's two")
        #expect(transport.reads == 1)
        #expect(Set(transport.lastReadCursors.keys) == declared,
                "every declared table's cursor rides the one call, or a quiet table is never asked about")
        #expect(transport.pushes == 0)
        #expect(transport.roundTrips == 1)
    }

    /// What a beat costs when the engine is woken by it, kept as the thing the fix is measured
    /// against: one changed row buys a push, and the full cycle it lands in buys the read too.
    @Test func aFullCycleDrivenByAPresenceRowCostsTwoRoundTrips() async throws {
        let server = FakeSyncServer()
        let transport = CountingTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        await device.enroll()
        await device.sync.syncNow(.full)

        let beat = PresenceHeartbeat(modelContext: device.container.mainContext,
                                     deviceID: "device-under-test",
                                     deviceName: "Test Mac")
        transport.reset()
        beat.beat()
        await device.sync.syncNow(.full)

        // One row of one table moved, and the account was still asked what it holds.
        #expect(transport.pushes == 1)
        #expect(transport.reads == 1)
        #expect(transport.roundTrips == 2)
    }

    /// The fix: a beat sends its row and reads nothing.
    @Test func aBeatSendsItsRowWithoutPullingAnything() async throws {
        let server = FakeSyncServer()
        let transport = CountingTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        await device.enroll()
        await device.sync.syncNow(.full)

        let beat = PresenceHeartbeat(modelContext: device.container.mainContext,
                                     deviceID: "device-under-test",
                                     deviceName: "Test Mac",
                                     send: { [sync = device.sync] in await sync.pushOnly() })
        transport.reset()
        beat.beat()
        await device.sync.pushOnly()

        #expect(transport.pushes == 1)
        #expect(transport.reads == 0)
        #expect(transport.roundTrips == 1)
    }

    /// And the row genuinely arrives — a cheaper path that quietly stopped delivering would be
    /// worse than the cost it saved.
    @Test func theRowStillReachesTheServer() async throws {
        let server = FakeSyncServer()
        let transport = CountingTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        await device.enroll()
        await device.sync.syncNow(.full)

        let beat = PresenceHeartbeat(modelContext: device.container.mainContext,
                                     deviceID: "arriving-device",
                                     deviceName: "Test Mac")
        beat.beat()
        await device.sync.pushOnly()

        let table = TranscriptionSyncSchema.schema.tables.first { $0.name.contains("presence") }
        #expect(table != nil)
        let landed = await server.liveCount(in: table?.name ?? "")
        #expect(landed == 1)
    }

    /// The hourly figure a Mac left open all day is quoted at — derived here from round trips
    /// counted in this test and the beat interval, rather than from a number written down beside
    /// them, which is the form that survives the cycle's shape changing underneath it.
    @Test func theHourlyCostFollowsFromTheMeasuredCycleAndTheInterval() async throws {
        let server = FakeSyncServer()
        let transport = CountingTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        await device.enroll()
        await device.sync.syncNow(.full)

        let beat = PresenceHeartbeat(modelContext: device.container.mainContext,
                                     deviceID: "hourly-cost",
                                     deviceName: "Test Mac")
        transport.reset()
        beat.beat()
        await device.sync.syncNow(.full)
        let wokenCycle = transport.roundTrips

        transport.reset()
        beat.beat()
        await device.sync.pushOnly()
        let beatAlone = transport.roundTrips

        let beatsPerHour = 3600.0 / PresenceHeartbeat.defaultInterval
        #expect(beatsPerHour == 60)
        #expect(beatsPerHour * Double(wokenCycle) == 120, "per open Mac, had the beat woken a whole cycle")
        #expect(beatsPerHour * Double(beatAlone) == 60, "and as the beat actually sends it")
    }
}
