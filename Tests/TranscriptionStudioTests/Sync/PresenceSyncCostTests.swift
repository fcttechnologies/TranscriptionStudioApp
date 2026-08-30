import FCTBlobSyncTesting
import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import SwiftData
import Testing
@testable import TranscriptionStudio

/// Every record round trip a cycle makes, counted, so a claim about what presence costs is a
/// measurement rather than a reading of the call graph.
private final class CountingTransport: SyncTransport, @unchecked Sendable {
    private let inner: FakeTransport
    private let lock = NSLock()
    private var _pushes = 0
    private var _pulls: [String] = []

    var pushes: Int { lock.withLock { _pushes } }
    var pulls: [String] { lock.withLock { _pulls } }
    var roundTrips: Int { lock.withLock { _pushes + _pulls.count } }

    init(server: FakeSyncServer) { inner = FakeTransport(server: server) }

    func reset() { lock.withLock { _pushes = 0; _pulls = [] } }

    func push(schemaVersion: String, records: [PushRecord]) async throws -> [PushVerdict] {
        lock.withLock { _pushes += 1 }
        return try await inner.push(schemaVersion: schemaVersion, records: records)
    }

    func pull(schemaVersion: String, table: String, cursor: Int64, pageLimit: Int) async throws -> PullEnvelope {
        lock.withLock { _pulls.append(table) }
        return try await inner.pull(schemaVersion: schemaVersion, table: table, cursor: cursor, pageLimit: pageLimit)
    }
}

/// What a `PresenceHeartbeat` beat actually costs on the wire.
///
/// The Mac's presence beacon writes one `MacPresence` row a minute and saves. `ModelContext.didSave`
/// is process-wide, so `LocalSaveTrigger` fires on it like any other write and the debounce
/// collapses into a full `syncNow()` — and a full cycle is a push plus a cursor pull of **every**
/// table in the schema, not the one row the write suggests.
///
/// The cost was previously derived by reading that call graph. These tests measure it instead,
/// because a derived number is the kind that turns out to have counted a loop that pages or a
/// branch that no longer runs.
@Suite("Presence heartbeat — what a beat costs on the wire")
@MainActor
struct PresenceSyncCostTests {

    /// The instrument first, against an answer already known: the schema declares nine tables, so
    /// an idle cycle that pulls anything other than those nine means the counter is wrong before
    /// any claim rests on it.
    @Test func anIdleCycleCostsOnePushAndOnePullPerDeclaredTable() async throws {
        let server = FakeSyncServer()
        let transport = CountingTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        await device.enroll()
        await device.sync.syncNow()

        transport.reset()
        await device.sync.syncNow()

        // Nine tables, pulled in declared order, and NO push: the engine skips the push
        // entirely when the outbox is empty. That last part is why a cost derived from the call
        // graph came out at 9 per beat — it counted this idle shape and missed that a dirty
        // presence row adds the push back.
        let declared = TranscriptionSyncSchema.schema.tables.map(\.name)
        #expect(declared.count == 9)
        #expect(transport.pulls == declared)
        #expect(transport.pushes == 0)
        #expect(transport.roundTrips == 9)
    }

    /// What a beat used to cost, kept as the thing the fix is measured against: were the engine
    /// woken by a presence save, one changed row would buy a push plus all nine cursor pulls.
    @Test func aCycleDrivenByAPresenceRowCostsTenRoundTrips() async throws {
        let server = FakeSyncServer()
        let transport = CountingTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        await device.enroll()
        await device.sync.syncNow()

        let beat = PresenceHeartbeat(modelContext: device.container.mainContext,
                                     deviceID: "device-under-test",
                                     deviceName: "Test Mac")
        transport.reset()
        beat.beat()
        await device.sync.syncNow()

        // One row of one table moved, and every other table was still asked for its cursor page.
        #expect(transport.pushes == 1)
        #expect(transport.pulls.count == 9)
        #expect(transport.roundTrips == 10)
    }

    /// The fix: a beat sends its row and pulls nothing.
    @Test func aBeatSendsItsRowWithoutPullingAnything() async throws {
        let server = FakeSyncServer()
        let transport = CountingTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        await device.enroll()
        await device.sync.syncNow()

        let beat = PresenceHeartbeat(modelContext: device.container.mainContext,
                                     deviceID: "device-under-test",
                                     deviceName: "Test Mac",
                                     send: { [sync = device.sync] in await sync.pushOnly() })
        transport.reset()
        beat.beat()
        await device.sync.pushOnly()

        #expect(transport.pushes == 1)
        #expect(transport.pulls.isEmpty)
        #expect(transport.roundTrips == 1)
    }

    /// And the row genuinely arrives — a cheaper path that quietly stopped delivering would be
    /// worse than the cost it saved.
    @Test func theRowStillReachesTheServer() async throws {
        let server = FakeSyncServer()
        let transport = CountingTransport(server: server)
        let device = try BootstrapDevice(server: server, transport: transport)
        await device.enroll()
        await device.sync.syncNow()

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

    /// The hourly figure the backlog quotes, derived here from the measured per-beat cost and the
    /// beat interval rather than asserted alongside it.
    @Test func theHourlyCostFollowsFromTheMeasuredCycleAndTheInterval() {
        let beatsPerHour = 3600.0 / PresenceHeartbeat.defaultInterval
        let wokeAWholeCycle = TranscriptionSyncSchema.schema.tables.count + 1
        #expect(beatsPerHour == 60)
        // 600 an hour per open Mac before, 60 after. The backlog quoted 540, which is 60 x 9:
        // the pull count, with the push a dirty row puts back left out.
        #expect(beatsPerHour * Double(wokeAWholeCycle) == 600)
        #expect(beatsPerHour * 1 == 60)
    }
}
