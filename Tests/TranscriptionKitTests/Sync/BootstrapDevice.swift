import FCTAccount
import FCTBlobSync
import FCTBlobSyncTesting
import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import SwiftData
import Testing
@testable import TranscriptionKit

/// One device driven through **this app's own bootstrap** — the composition root that ships,
/// not the harness fixture. Everything below asserts on a promise of `TranscriptionSync` rather
/// than of the engine, which the module's contract suite already covers.
@MainActor
final class BootstrapDevice {
    let sync: TranscriptionSync
    let container: ModelContainer
    let accountID: UUID
    let server: FakeSyncServer
    let objects: FakeBlobObjectStore

    private let storeURL: URL
    private let base: URL

    init(server: FakeSyncServer = FakeSyncServer(),
         objects: FakeBlobObjectStore = FakeBlobObjectStore(),
         accountID: UUID = UUID()) throws {
        self.server = server
        self.objects = objects
        self.accountID = accountID
        let made = try TestStoreFactory.onDisk(TranscriptionSchemaCurrent.self)
        container = made.container
        storeURL = made.url
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsa-bootstrap-\(UUID().uuidString)", isDirectory: true)

        let base = self.base
        sync = TranscriptionSync(configuration: TranscriptionSyncConfiguration(
            stateFileURL: { base.appendingPathComponent("syncstate.json") },
            blobStateFileURL: { base.appendingPathComponent("blobstate.json") },
            blobCacheDirectory: { base.appendingPathComponent("cache", isDirectory: true) },
            makeTransport: { _ in FakeTransport(server: server) },
            makeBlobTransport: { _ in FakeBlobTransport(store: objects) },
            // `LocalSaveTrigger` observes saves process-wide, so a test process would wake one
            // suite's engine on another suite's writes. Each harness supplies its own trigger set;
            // this one drives cycles explicitly.
            makeTriggers: { _ in [] }
        ))
        sync.attachForTesting(container: container)
        let account = FakeAccount(accountID: accountID)
        sync.currentAccount = { account }
    }

    func enroll() async {
        await sync.handle(.enrolled(accountID))
    }

    /// Record a session the way the app does before any account exists: bytes in the session's
    /// own column, nothing staged.
    @discardableResult
    func recordSession(title: String, audio: Data?) throws -> UUID {
        let context = container.mainContext
        let session = TranscriptSession(title: title, kind: .roomRecording)
        session.audioData = audio
        context.insert(session)
        try context.save()
        return session.id
    }

    func session(_ id: UUID) throws -> TranscriptSession? {
        try container.mainContext.fetch(TranscriptSession.descriptor(forSyncIDs: [id])).first
    }

    func tearDown() {
        sync.quiesceForTesting()
        TestStoreFactory.removeStore(at: storeURL)
        try? FileManager.default.removeItem(at: base)
    }
}

