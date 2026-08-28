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

/// The way back from a refusal, and the account's first pull — the two things a device that has
/// gone wrong needs, driven through this app's own bootstrap rather than through the engine.
@Suite("TranscriptionSync recovery and restore")
struct TranscriptionSyncRecoveryTests {

    // MARK: - The way back from a refusal

    /// A refusal blocks its own recovery: the drained-outbox barrier counts stuck entries, so a
    /// device holding refused work can neither rebuild from the server nor sign out. This is the
    /// one explicit action that releases it — and it has to reach **both** wires, because the row
    /// that reports refusals reports one number and an action that fixed half of it would be worse
    /// than none.
    ///
    /// A judged record and a refused recording upload together, so a fix that only released one is
    /// visible: the sign-out below still refuses if either is left behind.
    @MainActor
    @Test func retryingRefusedWorkReleasesBothWiresAndUnblocksTheBarrier() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        // A record the server judges, and a recording the object store refuses. The upload is
        // staged with the wire down first: the object path only exists once the sweep has minted
        // the ref, and the refusal has to be armed against that exact path.
        let judged = try device.recordSession(title: "Judged record", audio: nil)
        let uploaded = try device.recordSession(title: "Refused upload", audio: Data("bytes".utf8))
        await device.server.setRejecting([judged])
        await device.objects.setOnline(false)
        await device.enroll()

        let ref = try #require(try device.session(uploaded)?.audioAsset?.blobRef)
        let objectPath = BlobPath(
            account: device.accountID,
            app: TranscriptionSyncSchema.postgresSchema,
            blobID: ref.id
        ).objectPath
        await device.objects.setRejecting([objectPath])
        await device.objects.setOnline(true)
        await device.sync.syncNow()

        try #require(device.sync.counted.stuck == 1, "the record must be judged and parked")
        try #require(device.sync.blobCounted.stuck == 1, "and the upload refused and parked")
        #expect(device.sync.refusedUploads.count == 1,
                "the refused upload must be enumerable, not only countable")

        // The server-side repair the device cannot see: the collision resolved, the column added.
        await device.server.setRejecting([])
        await device.objects.setRejecting([])

        let requeued = await device.sync.retryRefused()
        #expect(requeued == 2, "both wires' refusals were released, not just the record engine's")
        #expect(device.sync.counted.stuck == 0)
        #expect(device.sync.blobCounted.stuck == 0)
        #expect(device.sync.unsyncedWork?.isDrained == true,
                "and the barrier that was blocking every route back is clear")

        // The proof that clearing the barrier actually restored the routes: the sign-out that was
        // being refused now runs.
        await device.sync.handle(.signedOut)
        #expect(device.sync.keptOnSignOut == 0)
        #expect(try device.container.mainContext.fetchCount(FetchDescriptor<TranscriptSession>()) == 0)
    }

    /// The cost of being wrong about the cause is one round trip: an entry the server still refuses
    /// comes straight back as failed, carrying a fresh reason rather than a stale one. It must not
    /// silently read as recovered.
    @MainActor
    @Test func aStillRefusedRecordComesBackRefused() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        let judged = try device.recordSession(title: "Permanently judged", audio: nil)
        await device.server.setRejecting([judged])
        await device.enroll()
        try #require(device.sync.counted.stuck == 1)

        let requeued = await device.sync.retryRefused()
        #expect(requeued == 1, "it was released")
        #expect(device.sync.counted.stuck == 1, "and judged again, because nothing about it changed")
    }

    // MARK: - The account's first pull

    /// The front door's restore seam, on a healthy account: the library actually lands, and the
    /// answer is the cycle's own verdict rather than a timer's.
    @MainActor
    @Test func restoringAHealthyAccountLandsTheLibraryAndSaysSo() async throws {
        let server = FakeSyncServer()
        let objects = FakeBlobObjectStore()
        let accountID = UUID()

        // One device writes the library, a second one restores it — the reinstall shape.
        let author = try BootstrapDevice(server: server, objects: objects, accountID: accountID)
        try author.recordSession(title: "Quarterly planning", audio: nil)
        await author.enroll()
        await author.sync.syncNow()
        author.tearDown()

        let restored = try BootstrapDevice(server: server, objects: objects, accountID: accountID)
        defer { restored.tearDown() }
        await restored.enroll()

        #expect(await restored.sync.restoreAccountData() == true)
        #expect(try restored.container.mainContext.fetchCount(FetchDescriptor<TranscriptSession>()) == 1,
                "a true answer has to mean the rows are here")
    }

    /// **The empty-state rule's load-bearing half.** An unreachable account and an empty one look
    /// identical from the device, so the restore must answer `false` rather than resolve into a
    /// surface that claims the library is empty.
    @MainActor
    @Test func anUnreachableAccountRefusesTheRestoreRatherThanReportingAnEmptyLibrary() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        await device.server.setOnline(false)
        await device.enroll()

        #expect(await device.sync.restoreAccountData() == false,
                "no answer is not the same as no data")
        #expect(try device.container.mainContext.fetchCount(FetchDescriptor<TranscriptSession>()) == 0)
    }

    /// With no engine at all, the restore refuses on its own deadline instead of reporting on a
    /// pull that never happened.
    @MainActor
    @Test func aRestoreWithNoEngineRefusesRatherThanAnsweringForOne() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        #expect(await device.sync.restoreAccountData(waitingUpTo: .milliseconds(150)) == false)
    }

    /// The third field failure, beside unreachable and refused: a server that answers correctly and
    /// **slowly**. A cycle already in flight is what `syncNow()` folds a second request into and
    /// returns from immediately, so a restore that did not wait would hand the front door a verdict
    /// about a pull that had not finished.
    @MainActor
    @Test func aSlowServerStillYieldsAVerdictAboutTheRealPull() async throws {
        let server = FakeSyncServer()
        let objects = FakeBlobObjectStore()
        let accountID = UUID()

        let author = try BootstrapDevice(server: server, objects: objects, accountID: accountID)
        try author.recordSession(title: "Design review", audio: nil)
        await author.enroll()
        await author.sync.syncNow()
        author.tearDown()

        let restored = try BootstrapDevice(server: server, objects: objects, accountID: accountID,
                                           transportLatency: .milliseconds(40))
        defer { restored.tearDown() }
        await restored.enroll()

        // A cycle deliberately already running when the restore asks.
        let inFlight = Task { await restored.sync.syncNow() }
        let answer = await restored.sync.restoreAccountData()
        await inFlight.value

        #expect(answer == true)
        #expect(try restored.container.mainContext.fetchCount(FetchDescriptor<TranscriptSession>()) == 1,
                "the true answer must describe a pull that actually landed the rows")
    }

    // MARK: - What a sign-out actually reclaims

    /// A recording is cached on disk permanently on the device that made it, so a sign-out that
    /// swept the rows and the queues but left the audio would leave the *bulk* of one account's
    /// data readable to whoever signs in next — the rows are kilobytes and the recordings are not.
    ///
    /// Asserted against the filesystem rather than against an API's answer, because the question
    /// is literally whether the bytes are still there.
    @MainActor
    @Test func aCompletedSignOutReclaimsTheRecordingCache() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        try device.recordSession(title: "Cached audio", audio: Data("real recording bytes".utf8))
        await device.enroll()
        await device.sync.syncNow()

        try #require(device.cachedFileCount > 0,
                     "the staging sweep must have written the recording into the cache")

        await device.sync.handle(.signedOut)

        #expect(device.sync.keptOnSignOut == 0, "the barrier let the clear through")
        #expect(device.cachedFileCount == 0, "and the cached audio went with the rows")
    }

    /// The barrier's other side: a clear that was refused keeps the library whole, and "whole"
    /// has to include the audio. Reclaiming the cache here would destroy the one copy of bytes
    /// the server has never held — which is the exact thing the refusal exists to prevent.
    @MainActor
    @Test func aRefusedSignOutKeepsTheRecordingCacheToo() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        try device.recordSession(title: "Never pushed", audio: Data("only copy".utf8))
        await device.objects.setOnline(false)
        await device.enroll()

        try #require(device.cachedFileCount > 0)
        await device.sync.handle(.signedOut)

        #expect(device.sync.keptOnSignOut > 0, "the barrier refused the clear")
        #expect(device.cachedFileCount > 0, "so the only copy of these bytes is still here")
    }

    // MARK: - Telling the front door its copy is gone

    /// A clear is what makes the next sign-in a *restore* rather than a resume onto an empty store,
    /// so the front door has to hear about it. It fires only when the clear actually ran.
    @MainActor
    @Test func aCompletedSignOutClearTellsTheFrontDoorItsCopyIsGone() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        var cleared = 0
        device.sync.onLocalDataCleared = { cleared += 1 }

        try device.recordSession(title: "Synced fine", audio: nil)
        await device.enroll()
        await device.sync.syncNow()
        await device.sync.handle(.signedOut)

        #expect(device.sync.keptOnSignOut == 0, "the barrier let it through")
        #expect(cleared == 1)
    }

    /// And a sign-out the barrier refused kept the library, so this device's copy is still the
    /// account's: telling the front door it was cleared would make the next sign-in pull down a
    /// library it already has.
    @MainActor
    @Test func aRefusedSignOutClearDoesNotTellTheFrontDoorAnything() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        var cleared = 0
        device.sync.onLocalDataCleared = { cleared += 1 }

        await device.server.setOnline(false)
        try device.recordSession(title: "Never pushed", audio: nil)
        await device.enroll()
        await device.sync.handle(.signedOut)

        #expect(device.sync.keptOnSignOut > 0, "the barrier refused the clear")
        #expect(cleared == 0)
    }

    /// An account switch is unconditionally destructive, so the front door hears about that one too.
    @MainActor
    @Test func anAccountSwitchTellsTheFrontDoorItsCopyIsGone() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        var cleared = 0
        device.sync.onLocalDataCleared = { cleared += 1 }

        try device.recordSession(title: "Account A's", audio: nil)
        await device.enroll()
        await device.sync.handle(.switched(from: device.accountID, to: UUID()))

        #expect(cleared == 1)
    }
}
