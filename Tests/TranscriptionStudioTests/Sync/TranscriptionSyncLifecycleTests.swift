import FCTAccount
import FCTBlobSync
import FCTBlobSyncTesting
import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import SwiftData
import Testing
@testable import TranscriptionStudio

/// The bootstrap's lifecycle mapping, pinned: which account events run the destructive sequence,
/// which are barrier-gated, and whether this app's composition root actually wires the blob
/// layer's ordering rule into the record engine.
@Suite("TranscriptionSync lifecycle mapping")
struct TranscriptionSyncLifecycleTests {

    // MARK: - The push gate, through this app's own composition root

    /// **The gate the shared suite structurally cannot prove.** `BlobContractScenario` wires its
    /// own `pushGate` on its own fixture engine, so it proves the machinery works wherever it is
    /// wired — and passes identically for an app that never wires it. Every shipped adopter wires
    /// it inline in its bootstrap; there is no shared hook to reach.
    ///
    /// So: stage a real recording through the shipping path (`syncNow` runs the staging sweep),
    /// refuse the upload transport, run a full ordinary cycle, and assert the session never
    /// reached the server and stayed *pending* — held, never pushed, never failed.
    @MainActor
    @Test func pushGateHoldsASessionWhoseRecordingHasNotUploaded() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        let bytes = Data("the user's own recording, megabytes in real life".utf8)
        let sessionID = try device.recordSession(title: "Held", audio: bytes)
        await device.objects.setOnline(false)
        await device.enroll()

        // The sweep ran: the bytes moved out of the session's own column and into the blob layer.
        let staged = try #require(try device.session(sessionID))
        #expect(staged.audioData == nil, "the staging sweep must clear the pre-staging column")
        let ref = try #require(staged.audioAsset?.blobRef, "and write the asset in its place")

        // The upload could not land, so the record must not have gone out with it.
        let rows = await device.server.liveCount(in: TranscriptSession.syncTableName)
        #expect(rows == 0, """
        the session reached the server while its recording was still on the device: the engine's \
        push gate is not wired to the blob store, so the ordering rule is not in force
        """)
        #expect(device.sync.unsyncedWork?.isDrained == false, "the held work is surfaced, never inferred")

        // The other side of the same wire: the upload lands, the gate opens, the record goes.
        await device.objects.setOnline(true)
        await device.sync.syncNow()
        let pushed = await device.server.liveCount(in: TranscriptSession.syncTableName)
        #expect(pushed == 1, "the confirmed upload must release the session through the same gate")
        let stored = await device.objects.object(at: BlobPath(
            account: device.accountID, app: TranscriptionSyncSchema.postgresSchema, blobID: ref.id))
        #expect(stored?.bytes == bytes, "the authored bytes are on the object store")
    }

    /// A recording past the object store's per-file cap is refused at **stage** time, and this is
    /// the app most able to reach it: 32 kbps mono is ~14.4 MB/hour, so 50 MB is ~3.5 hours of one
    /// meeting.
    ///
    /// That must cost the long session its upload and nothing else. The sweep runs oldest-first,
    /// so a refusal allowed out of the loop ends the pass where it stands: every session recorded
    /// *after* the long one stages on no cycle ever, because the same refusal waits at the same
    /// place every time. One long meeting is not a wedge for the library behind it.
    @MainActor
    @Test func anOverCapRecordingKeepsItsAudioLocalWithoutWedgingTheSweep() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        // Oldest first, so the long session sits between two ordinary ones: one the sweep reaches
        // before the refusal, one it only reaches by surviving it.
        let before = try device.recordSession(
            title: "Standup", audio: Data("short and ordinary".utf8),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let oversize = try device.recordSession(
            title: "Six-hour offsite", audio: Data(count: Int(BlobPolicy.maxObjectBytes) + 1),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let after = try device.recordSession(
            title: "Retro", audio: Data("also short".utf8),
            createdAt: Date(timeIntervalSince1970: 3_000)
        )

        await device.enroll()

        let long = try #require(try device.session(oversize))
        #expect(long.audioAsset == nil, "over the cap, so nothing was staged")
        #expect(long.audioData != nil, "and the bytes stay readable on the device that recorded them")

        for (id, name) in [(before, "ahead of it"), (after, "behind it")] {
            let session = try #require(try device.session(id))
            #expect(session.audioAsset != nil, "the session \(name) stages")
            #expect(session.audioData == nil, "and its pre-staging column is cleared")
        }

        // Every row still reaches the server: what an over-cap session loses is its audio, not its
        // record — title, transcript and segments are ordinary columns and travel as usual.
        #expect(await device.server.liveCount(in: TranscriptSession.syncTableName) == 3)
        #expect(device.sync.unsyncedWork?.isDrained == true, "and nothing is left held")

        #expect(await device.objects.objectCount() == 2, "only the two ordinary recordings uploaded")
    }

    // MARK: - The destructive mappings

    @MainActor
    @Test func switchedRunsTheDestructiveSequence() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        await device.server.setOnline(false)
        try device.recordSession(title: "A's meeting", audio: nil)
        await device.enroll()
        #expect(device.sync.unsyncedWork?.isDrained == false, "the switch must be discarding real unpushed work")

        await device.sync.handle(.switched(from: device.accountID, to: UUID()))

        // Account A's rows must not survive into account B — pushed or not.
        let context = device.container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSession>()) == 0)
        #expect(device.sync.discardedOnSwitch > 0,
                "the one moment this app can lose a write is surfaced, never swallowed")
    }

    @MainActor
    @Test func signedOutClearsOnceEverythingHasSynced() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        let bytes = Data("recorded, uploaded, acked".utf8)
        try device.recordSession(title: "Fully synced", audio: bytes)
        await device.enroll()
        #expect(device.sync.unsyncedWork?.isDrained == true, "the barrier's precondition must actually hold")

        await device.sync.handle(.signedOut)

        // Everything this app holds syncs — records through the engine, the recording through the
        // blob layer — and the barrier just proved the server has all of it. So sign-out removes
        // it from this device, and a re-sign-in restores it.
        let context = device.container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSession>()) == 0)
        #expect(device.sync.status == .off)
        #expect(device.sync.keptOnSignOut == 0)
        let rows = await device.server.liveCount(in: TranscriptSession.syncTableName)
        #expect(rows == 1, "the server's copy is untouched — sign-out ends a session, not the data")
    }

    @MainActor
    @Test func signedOutWithUnpushedWorkKeepsTheStoreWhole() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        await device.server.setOnline(false)
        try device.recordSession(title: "Never pushed", audio: nil)
        await device.enroll()
        #expect(device.sync.unsyncedWork?.isDrained == false)

        await device.sync.handle(.signedOut)

        // Between a local write and its push ack this device is the only holder of that change:
        // the barrier refuses the clear, and the library outlives the session.
        let context = device.container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSession>()) == 1)
        #expect(device.sync.keptOnSignOut > 0, "the kept work is surfaced, never silent")
        #expect(device.sync.status == .off)
    }

    /// A recording whose upload never landed is unpushed work too, even when every *record* has
    /// been acked — the barrier reads both layers or it clears a library whose bytes exist
    /// nowhere else.
    @MainActor
    @Test func signedOutWithAnUndrainedUploadKeepsTheStoreWhole() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        await device.objects.setOnline(false)
        try device.recordSession(title: "Bytes still here", audio: Data("only on this device".utf8))
        await device.enroll()

        await device.sync.handle(.signedOut)

        let context = device.container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSession>()) == 1)
        #expect(device.sync.keptOnSignOut > 0)
    }

    /// **Refused** work is unsynced work, and it is the half waiting cannot fix.
    ///
    /// A record the server judged leaves the pending set for good and is never auto-retried, so
    /// counting only what is pending reports nothing outstanding for exactly the entry that can
    /// never go by itself — and that is the number the sign-out UI decides from.
    ///
    /// Two refused records rather than one, deliberately: the kept-count's floor reports "1" no
    /// matter what, so a single record would let a pending-only count look right by coincidence.
    /// Two is what tells a real count from a fabricated one.
    @MainActor
    @Test func refusedRecordsAreCountedAsUnsyncedWorkAndReportedWhenTheStoreIsKept() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        let first = try device.recordSession(title: "Refused one", audio: nil)
        let second = try device.recordSession(title: "Refused two", audio: nil)
        await device.server.setRejecting([first, second])
        await device.enroll()

        // The trap, armed: durably failed and out of the pending set, so a pending-only count
        // reads zero while the outbox demonstrably holds both.
        let state = device.syncStateFile.read()
        try #require(state.counted.stuck == 2, "both refusals must have parked their entries")
        try #require(state.counted.retrying == 0, "and both must have left the pending set")

        #expect(device.sync.unsyncedWork?.total == 2, "refused work is still work the server never took")

        // The published half the rows render, which is the *durable* surface. The headline
        // carries a refused count too, but only until the next cycle overwrites it — one dropped
        // connection makes it `.offline`, a later clean cycle makes it `.idle`, and both advise
        // waiting for something waiting can never clear. A queued-only count reads zero here.
        #expect(device.sync.counted.retrying == 0, "nothing is queued — waiting would change nothing")
        #expect(device.sync.counted.stuck == 2,
                "and the row must be able to say two changes need attention")

        await device.sync.handle(.signedOut)

        let context = device.container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSession>()) == 2,
                "the barrier refuses the clear")
        #expect(device.sync.keptOnSignOut == 2,
                "and the note names what was actually held, not a floor")
    }

    /// A **recording** the object store refused is stuck for the same reason a judged record is:
    /// it left the pending set, is never auto-retried, and only a fresh local edit brings it back.
    /// So both surfaces that give advice about it have to see it — the settings row's
    /// needs-attention half and the sign-out barrier's count — or the one entry waiting can never
    /// clear is the one entry that reads as nothing outstanding.
    ///
    /// The record layer's own refusal is pinned above; this is the blob layer's, which no app
    /// suite in the fleet otherwise exercises.
    @MainActor
    @Test func aRefusedRecordingUploadIsSurfacedAsStuckOnBothCounts() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        // Staged with the wire down first: the object path only exists once the sweep has minted
        // the ref, and the refusal has to be armed against that exact path.
        let sessionID = try device.recordSession(
            title: "Refused upload", audio: Data("only on this device".utf8)
        )
        await device.objects.setOnline(false)
        await device.enroll()
        let ref = try #require(try device.session(sessionID)?.audioAsset?.blobRef,
                               "the staging sweep must have minted the ref")

        // Wire back, this object refused. A refusal is not connectivity, so the entry is judged
        // and parked rather than left pending — the state waiting cannot change.
        await device.objects.setRejecting([BlobPath(
            account: device.accountID,
            app: TranscriptionSyncSchema.postgresSchema,
            blobID: ref.id
        ).objectPath])
        await device.objects.setOnline(true)
        await device.sync.syncNow()

        #expect(device.sync.blobCounted.stuck == 1,
                "the refused recording is the row's needs-attention half")
        #expect(device.sync.blobCounted.retrying == 0,
                "and it has left the queued half — the row must not advise waiting for it")
        #expect(device.sync.unsyncedWork?.stuck == 1,
                "the sign-out barrier counts it too: these bytes exist nowhere but this device")
    }

    /// `.resumed` re-fires on every foregrounding, so the bootstrap must recognise its own living
    /// engine and just run a cycle. Rebuilding would accumulate a trigger task and observer set
    /// per foreground — invisible from the outside, which is why the build count is the assertion.
    @MainActor
    @Test func resumingTheSameAccountDoesNotRebuildTheEngine() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        await device.enroll()
        #expect(device.sync.engineBuildCountForTesting == 1)

        await device.sync.handle(.resumed(device.accountID))
        await device.sync.handle(.resumed(device.accountID))
        #expect(device.sync.engineBuildCountForTesting == 1,
                "a foregrounding is a cycle, not a new engine")
    }

    /// Involuntary: nothing local is cleared and the outbox is untouched, so one sign-in resumes.
    @MainActor
    @Test func needsReauthenticationClearsNothing() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        await device.server.setOnline(false)
        try device.recordSession(title: "Still mine", audio: nil)
        await device.enroll()

        await device.sync.handle(.needsReauthentication(device.accountID))

        let context = device.container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSession>()) == 1)
        #expect(device.sync.status == .needsReauthentication)
    }
}

