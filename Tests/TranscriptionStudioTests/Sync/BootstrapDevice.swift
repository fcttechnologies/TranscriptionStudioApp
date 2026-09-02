import FCTAccount
import FCTAccountProfile
import FCTBlobSync
import FCTBlobSyncTesting
import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import SwiftData
import Testing
@testable import TranscriptionStudio

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

    /// - Parameter transportLatency: a delay in front of every record round trip. The field serves
    ///   slow answers as often as failed ones, and a cycle that is merely *slow* is the case a
    ///   concurrency guard gets wrong — it makes an in-flight cycle wide enough for a second caller
    ///   to arrive inside it.
    /// - Parameter transport: the wire itself, for a suite that has to watch the round trip rather
    ///   than only its result. Overrides `transportLatency`.
    /// - Parameter triggers: the change triggers the engine listens on. Empty by default, so a
    ///   suite drives cycles explicitly; a suite about the trigger path supplies its own.
    init(server: FakeSyncServer = FakeSyncServer(),
         objects: FakeBlobObjectStore = FakeBlobObjectStore(),
         accountID: UUID = UUID(),
         transportLatency: Duration = .zero,
         transport: (any SyncTransport)? = nil,
         triggers: [any HistoryChangeTrigger] = []) throws {
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
            accountBlobStateFileURL: { base.appendingPathComponent("account-blobstate.json") },
            accountBlobCacheDirectory: { base.appendingPathComponent("account-cache", isDirectory: true) },
            makeTransport: { _ -> any SyncTransport in
                if let transport { return transport }
                let fake = FakeTransport(server: server)
                guard transportLatency != .zero else { return fake }
                return LaggingTransport(wrapping: fake, delay: transportLatency)
            },
            makeBlobTransport: { _ in FakeBlobTransport(store: objects) },
            // `LocalSaveTrigger` observes saves process-wide, so a test process would wake one
            // suite's engine on another suite's writes. Each harness names the trigger set it
            // wants; none of them is the shipping one.
            makeTriggers: { _ in triggers }
        ))
        sync.attachForTesting(container: container)
        let account = FakeAccount(accountID: accountID)
        sync.currentAccount = { account }
    }

    func enroll() async {
        await sync.handle(.enrolled(accountID, appleFullName: nil))
    }

    /// The engine's durable state, for asserting on the outbox itself rather than on a surface
    /// that summarises it.
    var syncStateFile: SyncStateFile { SyncStateFile(url: base.appendingPathComponent("syncstate.json")) }

    /// Where the recording cache lands on disk — the same URL the live configuration hands the
    /// blob store. Asserting on the directory rather than on an API answer is the point: whether
    /// bytes are still readable after a sign-out is a question about the filesystem.
    var blobCacheDirectory: URL { base.appendingPathComponent("cache", isDirectory: true) }

    /// The files actually sitting in that cache right now.
    var cachedFileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: blobCacheDirectory.path).count) ?? 0
    }

    /// A second store over this device's account blob paths — what a relaunch would read, and the
    /// only way to ask whether a clear reached the cache after the bootstrap dropped its store.
    var accountBlobsOnDisk: AccountBlobStore {
        AccountBlobStore(
            account: FakeAccount(accountID: accountID),
            transport: FakeBlobTransport(store: objects),
            stateFileURL: base.appendingPathComponent("account-blobstate.json"),
            cacheDirectory: base.appendingPathComponent("account-cache", isDirectory: true)
        )
    }

    /// Record a session the way the app does before any account exists: bytes in the session's
    /// own column, nothing staged.
    ///
    /// `createdAt` is settable because the staging sweep runs oldest-first: a test about which
    /// session the sweep reaches first has to say so rather than lean on wall-clock ordering.
    @discardableResult
    func recordSession(title: String, audio: Data?, createdAt: Date = .now) throws -> UUID {
        let context = container.mainContext
        let session = TranscriptSession(title: title, kind: .roomRecording)
        session.audioData = audio
        session.createdAt = createdAt
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

/// A server that answers correctly, slowly. The third failure the field serves — beside
/// unreachable and refused — and the only one that gives a second caller a window to arrive inside
/// a cycle that has already started.
nonisolated struct LaggingTransport: SyncTransport {
    let wrapped: any SyncTransport
    let delay: Duration

    init(wrapping wrapped: any SyncTransport, delay: Duration) {
        self.wrapped = wrapped
        self.delay = delay
    }

    func push(schemaVersion: String, records: [PushRecord]) async throws -> [PushVerdict] {
        try await Task.sleep(for: delay)
        return try await wrapped.push(schemaVersion: schemaVersion, records: records)
    }

    func pullAll(
        schemaVersion: String,
        cursors: [String: Int64],
        rowBudget: Int
    ) async throws -> PullAllEnvelope {
        try await Task.sleep(for: delay)
        return try await wrapped.pullAll(schemaVersion: schemaVersion, cursors: cursors,
                                         rowBudget: rowBudget)
    }
}

/// Every record round trip a cycle makes, counted, so a claim about what a cycle costs on the wire
/// is a measurement rather than a reading of the call graph.
final class CountingTransport: SyncTransport, @unchecked Sendable {
    private let inner: FakeTransport
    private let lock = NSLock()
    private var _pushes = 0
    private var _reads = 0
    private var _lastCursors: [String: Int64] = [:]

    var pushes: Int { lock.withLock { _pushes } }
    /// One per cycle that reads at all: the whole declaration comes back in a single call.
    var reads: Int { lock.withLock { _reads } }
    /// Which tables the last read asked about — every table the client holds a cursor for, which
    /// is what makes "one call" a claim about the whole schema rather than about one table.
    var lastReadCursors: [String: Int64] { lock.withLock { _lastCursors } }
    var roundTrips: Int { lock.withLock { _pushes + _reads } }

    init(server: FakeSyncServer) { inner = FakeTransport(server: server) }

    func reset() { lock.withLock { _pushes = 0; _reads = 0 } }

    func push(schemaVersion: String, records: [PushRecord]) async throws -> [PushVerdict] {
        lock.withLock { _pushes += 1 }
        return try await inner.push(schemaVersion: schemaVersion, records: records)
    }

    func pullAll(
        schemaVersion: String,
        cursors: [String: Int64],
        rowBudget: Int
    ) async throws -> PullAllEnvelope {
        lock.withLock {
            _reads += 1
            _lastCursors = cursors
        }
        return try await inner.pullAll(schemaVersion: schemaVersion, cursors: cursors,
                                       rowBudget: rowBudget)
    }
}

