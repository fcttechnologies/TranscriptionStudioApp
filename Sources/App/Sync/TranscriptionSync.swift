import FCTAccount
import FCTBlobSync
import FCTServerSync
import FCTSync
import Foundation
import Network
import OSLog
import SwiftData

/// `FCTAccount` satisfies the engine's account seam by shape; this is the line that joins them.
/// The account module never links a sync engine, and the engine never links the account module —
/// the app wires the two, which is what keeps an app that syncs nothing able to have an account.
extension AccountCredentials: @retroactive SyncAccount {}

/// What the bootstrap builds an engine *from*: where the durable files live, how the wire is
/// made, and which change triggers it listens on. `.live` is the shipping wiring; tests point the
/// same bootstrap at temp files and `FakeSyncServer`-backed transports, which is the only way to
/// drive the account-event mapping without a live backend and the real on-device state file.
@MainActor
struct TranscriptionSyncConfiguration {
    var stateFileURL: () throws -> URL
    var blobStateFileURL: () throws -> URL
    var blobCacheDirectory: () throws -> URL
    var makeTransport: (any SyncAccount) -> any SyncTransport
    var makeBlobTransport: (any SyncAccount) -> any BlobTransport
    /// The change triggers the engine listens on, beside the bootstrap's own manual pulse.
    /// `LocalSaveTrigger` observes saves *process-wide*, which is right in an app and wrong in a
    /// test process, where it would wake one suite's engine on another suite's writes.
    var makeTriggers: (ModelContainer) -> [any HistoryChangeTrigger]

    init(
        stateFileURL: @escaping () throws -> URL,
        blobStateFileURL: @escaping () throws -> URL,
        blobCacheDirectory: @escaping () throws -> URL,
        makeTransport: @escaping (any SyncAccount) -> any SyncTransport,
        makeBlobTransport: @escaping (any SyncAccount) -> any BlobTransport,
        makeTriggers: @escaping (ModelContainer) -> [any HistoryChangeTrigger]
    ) {
        self.stateFileURL = stateFileURL
        self.blobStateFileURL = blobStateFileURL
        self.blobCacheDirectory = blobCacheDirectory
        self.makeTransport = makeTransport
        self.makeBlobTransport = makeBlobTransport
        self.makeTriggers = makeTriggers
    }

    static var live: TranscriptionSyncConfiguration {
        TranscriptionSyncConfiguration(
            stateFileURL: { try AppModelContainer.syncStateFileURL() },
            blobStateFileURL: { try AppModelContainer.blobStateFileURL() },
            blobCacheDirectory: { try AppModelContainer.blobCacheDirectory() },
            makeTransport: { account in
                PostgRESTTransport(
                    baseURL: AccountEnvironment.fct.baseURL,
                    publishableKey: AccountEnvironment.fct.publishableKey,
                    account: account
                )
            },
            makeBlobTransport: { account in
                SupabaseStorageTransport(
                    baseURL: AccountEnvironment.fct.baseURL,
                    publishableKey: AccountEnvironment.fct.publishableKey,
                    account: account
                )
            },
            // The cross-process rung is what makes a Share-extension or App-Intent write reach the
            // server without waiting for the app's next foreground — on the platforms where it fires.
            makeTriggers: { container in
                var triggers: [any HistoryChangeTrigger] = [LocalSaveTrigger()]
                if let remote = try? RemoteHistoryChangeTrigger(container: container) {
                    triggers.append(remote)
                }
                return triggers
            }
        )
    }
}

/// Transcription Studio's sync bootstrap: the account's lifecycle mapped onto the record engine's
/// and the blob store's, the triggers wired to the real events, and the one status surface
/// Settings renders.
///
/// **The engine exists only while an account does** — not an optional account threaded through
/// every push, pull and drain to express a state the engine can simply not exist in. The blob
/// store lives and dies with it: no account, no blob store, and pre-account recordings wait in
/// `TranscriptSession.audioData` until enrollment stages them.
///
/// **Signing out of Transcription Studio clears the local library, and the barrier is what makes
/// that safe.** Everything this app holds syncs: the sessions, every transcript segment, the
/// extracted highlights and speaker bindings as records, and the recordings themselves as
/// authored blobs. So once the outbox and the upload queue are both drained, the server holds all
/// of it and a re-sign-in gives it back. The one thing sync cannot restore is work it has never
/// seen, so unpushed records *or* undrained uploads refuse the clear and the store is kept whole
/// (``keptOnSignOut``); the sign-out UI surfaces push-or-discard through ``unsyncedWork`` before
/// the session is destroyed at all. `.switched` and `.deleted` clear unconditionally — one
/// account's library must not survive into another's, and a deletion means gone.
@MainActor
@Observable
final class TranscriptionSync {
    private(set) var status: SyncStatus = .off
    private(set) var lastSyncedAt: Date?
    /// The record outbox, split by whether waiting will clear it. Two numbers rather than one
    /// because they lead to opposite advice: `retrying` goes by itself, `stuck` never will.
    private(set) var counted: OutboxCensus = OutboxCensus()
    private(set) var blobPendingCount: Int = 0
    private(set) var lastError: String?
    /// Set when an account switch or deletion discarded local changes the server never saw.
    /// Surfaced rather than swallowed: it is the one moment this app can lose a write.
    private(set) var discardedOnSwitch: Int = 0
    /// Set when a sign-out left the library in place because unpushed work made the clear unsafe.
    private(set) var keptOnSignOut: Int = 0

    /// The blob store, alive exactly as long as the engine is. Playback reads it for the lazy
    /// full-bytes fetch of a restored recording.
    private(set) var blobStore: BlobStore?

    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private let manual = ManualTrigger()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var triggerTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var syncInFlight = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private weak var controller: AccountController?
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private let configuration: TranscriptionSyncConfiguration
    /// Server-applied writes bypass every app write seam, so the Spotlight index hears about them
    /// only here.
    @ObservationIgnored var onRemoteChanges: (@MainActor () -> Void)?
    /// The account the engine is built from — the controller's credentials in production, a fake
    /// in the bootstrap tests.
    @ObservationIgnored var currentAccount: () -> (any SyncAccount)? = { nil }
    /// Test seam: how many engines this bootstrap has built. The foregrounding guard is invisible
    /// from the outside otherwise — a rebuild reads the same state file and leaves the same rows —
    /// and a build is exactly what leaks a trigger task, so the count is both the assertable fact
    /// and the cost being counted.
    @ObservationIgnored private(set) var engineBuildCountForTesting = 0

    init(configuration: TranscriptionSyncConfiguration = .live) {
        self.configuration = configuration
    }

    /// Unpushed work across both layers — records the engine has not acked plus recording uploads
    /// the object store has not confirmed — split by whether waiting will clear them. The sign-out
    /// barrier: while this holds anything the UI surfaces push-or-discard before any clear runs.
    ///
    /// `nil` where there is no engine to ask — a count this device cannot take, which is not the
    /// same as a zero and must never be spelled as one at the moment a clear is being decided.
    ///
    /// Both halves of both layers, because the whole outbox is the same predicate the engine's own
    /// barrier counts: a refused record leaves the pending set and is never auto-retried, so a
    /// pending-only count reports nothing to lose for the one entry that can never go by itself.
    /// A refused upload is `stuck` for the same reason a judged record is.
    var unsyncedWork: OutboxCensus? {
        guard let engine else { return nil }
        var census = engine.state.counted
        if let blobCensus = blobStore?.counted {
            census.retrying += blobCensus.retrying
            census.stuck += blobCensus.stuck
        }
        return census
    }

    // MARK: - Bootstrap

    /// Wire the account's events to the engine's lifecycle. Called once, from the app root.
    func start(controller: AccountController, container: ModelContainer) {
        guard eventTask == nil else { return }
        self.controller = controller
        self.container = container
        self.currentAccount = { [weak controller] in controller?.credentials }

        let events = controller.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        startPathMonitor()
    }

    /// Test seam: the bootstrap normally learns the container from ``start(controller:container:)``;
    /// harness tests wire it directly, because constructing a real `AccountController` would touch
    /// the live keychain.
    func attachForTesting(container: ModelContainer) {
        self.container = container
    }

    /// Test seam: cancel the engine's live tasks before a harness deletes its store.
    func quiesceForTesting() {
        stopEngine(releasing: true)
    }

    /// Launch and every foregrounding. Unconditional, cursor-cheap, and the rung correctness
    /// actually rides on — everything above it only buys freshness.
    func foregrounded() {
        guard engine != nil else { return }
        engine?.resetBackoff()
        blobStore?.resetBackoff()
        manual.fire()
        Task { await syncNow() }
    }

    /// Force a full cycle now — the post-sign-in path. Stages any recording still living in the
    /// session's local byte column, drains the upload queue, then runs the record engine (whose
    /// push gate holds any session whose upload has not confirmed).
    ///
    /// A cycle already in flight is not joined by a second one; the request is remembered and the
    /// loop runs again once — the applier's own save fires `LocalSaveTrigger`, so every pull that
    /// lands rows asks for another cycle, which is correct and would otherwise re-enter.
    func syncNow() async {
        guard let engine else { return }
        if syncInFlight {
            syncAgain = true
            return
        }
        syncInFlight = true
        defer { syncInFlight = false }
        repeat {
            syncAgain = false
            await stageAuthoredAudio()
            if let blobStore { _ = await blobStore.sync() }
            let result = await engine.sync()
            publish(result)
            scheduleRetry(after: result)
        } while syncAgain
    }

    /// Coalesce a burst of triggers into one cycle: a finishing transcription saves its session,
    /// then hundreds of segments, then the extraction pass's highlights, and each save is a round
    /// trip if nothing gathers them.
    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Rebuild this device's view from the server. Refuses while anything is unpushed.
    func fullResync() async {
        guard let engine else { return }
        do {
            try await engine.fullResync()
            publish(engine.status)
        } catch {
            lastError = "\(error)"
            publish(engine.status)
        }
    }

    // MARK: - Rule 7: the staging sweep

    /// Move a recording out of `TranscriptSession.audioData` and into the blob layer: stage
    /// (cache + durable upload queue), then write the `AssetSource` back onto the session and
    /// clear the byte column, in one save. The write dirties the session, and the engine's push
    /// gate holds it until its upload confirms — so no device ever pulls a session whose
    /// recording the object store cannot serve.
    ///
    /// One path for both shapes: the enrollment backlog (a library recorded before the account
    /// existed) and every new recording archived while signed in. No-ops in a handful of
    /// microseconds when nothing is pending.
    ///
    /// **This is the only writer that moves a session across the two columns**, which is the whole
    /// of the at-most-one-non-nil invariant: nothing in the type system holds it.
    private func stageAuthoredAudio() async {
        guard let blobStore, let container else { return }
        let context = ModelContext(container)
        context.author = AppModelContainer.localAuthorName
        do {
            // Oldest first, so the pass's order is the library's rather than the store's: a
            // session the object store refuses is skipped, and a fixed order is what keeps that
            // skip from depending on which row the fetch happened to return first.
            let pending = try context.fetch(FetchDescriptor<TranscriptSession>(
                predicate: #Predicate { $0.audioData != nil },
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            ))
            guard !pending.isEmpty else { return }
            for session in pending {
                guard let bytes = session.audioData else { continue }
                let ref: BlobRef
                do {
                    ref = try blobStore.stage(
                        bytes,
                        contentType: "audio/mp4",
                        // No preview: a recording has no thumbnail, and a waveform would be a
                        // derived artifact bought at kilobytes on every session row. The list
                        // renders from the synced metadata (title, duration, date) it already has.
                        preview: nil,
                        owner: BlobOwner(table: TranscriptSession.syncTableName, uuid: session.id)
                    )
                } catch let error as BlobStoreError {
                    // A session past the object store's per-file cap is refused at stage time —
                    // ~3.5 hours at 32 kbps, which a long meeting reaches. Skipped rather than
                    // rethrown: an over-cap recording is a permanent condition, and letting it out
                    // of the loop would end the pass there on every cycle, so every session
                    // recorded after it would stage on no cycle ever.
                    //
                    // What that session loses is its audio alone — its record, transcript,
                    // segments and highlights sync as usual, and the bytes stay readable on the
                    // device that recorded them.
                    guard case .tooLarge = error else { throw error }
                    Logger.persistence.error(
                        "session audio over the object store cap, kept on device: bytes=\(bytes.count, privacy: .public)"
                    )
                    continue
                }
                session.audioAsset = .authored(ref)
                session.audioData = nil
            }
            try context.save()
        } catch {
            lastError = "\(error)"
            Logger.persistence.error("recording staging failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A session's recording bytes: the permanent local cache when they are here (always true on
    /// the device that recorded it), a lazy digest-verified fetch when they are not (a restored
    /// device's first play). Nil when the session is still pre-staging or no blob store exists —
    /// the caller falls back to `audioData`.
    func recordingData(for asset: AssetSource) async throws -> Data? {
        guard let blobStore, let ref = asset.blobRef else { return nil }
        if let cached = blobStore.cachedData(for: ref) { return cached }
        return try await blobStore.data(for: ref)
    }

    /// The synchronous cache-only read, for surfaces deciding whether to play now or show a
    /// fetching state.
    func cachedRecordingData(for asset: AssetSource) -> Data? {
        guard let blobStore, let ref = asset.blobRef else { return nil }
        return blobStore.cachedData(for: ref)
    }

    /// A deleted session's staged recording is released and its object queued for deletion — the
    /// delete paths collect these *before* the session goes.
    func discardRecording(_ asset: AssetSource?) {
        guard let blobStore, let asset, let ref = asset.blobRef else { return }
        blobStore.discard(ref)
        Task { _ = await blobStore.sync() }
    }

    // MARK: - Account lifecycle

    func handle(_ event: AccountEvent) async {
        switch event {
        case .enrolled(let accountID):
            await startEngine(accountID: accountID, enrolling: true)
        case .resumed(let accountID):
            await startEngine(accountID: accountID, enrolling: false)
        case .switched(_, let to):
            // A different account. Account A's library must not silently become account B's, so
            // this clears — and it discards whatever A never managed to push, because A's
            // credentials are already gone. The discard is surfaced, never swallowed.
            discardLocalData()
            await startEngine(accountID: to, enrolling: true)
        case .needsReauthentication:
            // Involuntary. The engine idles; nothing local is cleared, the outbox is untouched,
            // and one sign-in resumes.
            stopEngine(releasing: false)
            status = .needsReauthentication
        case .signedOut:
            // Deliberate — and this app CLEARS, barrier-gated. Records and recordings both sync,
            // so once both queues are drained the server holds the whole library and a re-sign-in
            // restores it; the barrier is what proves that at the moment of the act rather than
            // assuming it.
            clearOnSignOut()
            status = .off
        case .deleted:
            // The user asked for the data to be gone, here and everywhere. 5.1.1(v) is the whole
            // reason this branch is unconditionally destructive and the sign-out branch is not.
            stopEngine(releasing: true)
            discardLocalData()
            status = .off
        }
        refreshCounters()
    }

    private func startEngine(accountID: UUID, enrolling: Bool) async {
        guard let container, let credentials = currentAccount() else { return }
        guard credentials.accountID == accountID else { return }

        // `resume()` re-emits `.resumed` on every foregrounding, so this runs repeatedly for one
        // living engine: same account, not enrolling → just run a cycle. Rebuilding the trigger
        // wiring here would accumulate a task + observer set per foreground.
        if let engine, !enrolling, engine.accountID == accountID {
            await syncNow()
            return
        }
        stopEngine(releasing: true)

        let stateFile: SyncStateFile
        let blobs: BlobStore
        do {
            stateFile = SyncStateFile(url: try configuration.stateFileURL())
            blobs = BlobStore(
                // The slug IS the synced Postgres schema: blob keys are
                // `<account>/<schema>/<blob id>` and the per-app erase resolves its sweep prefix
                // from the schema name directly. Pinned by the blob contract suite.
                appSlug: TranscriptionSyncSchema.postgresSchema,
                account: credentials,
                transport: configuration.makeBlobTransport(credentials),
                stateFileURL: try configuration.blobStateFileURL(),
                cacheDirectory: try configuration.blobCacheDirectory()
            )
        } catch {
            lastError = "\(error)"
            status = .failed(count: 1)
            return
        }

        let engine = SyncEngine(
            container: container,
            stateFile: stateFile,
            transport: configuration.makeTransport(credentials),
            account: credentials,
            schema: TranscriptionSyncSchema.schema
        )
        // The ordering rule's engine half: a session whose recording upload is pending or failed
        // stays *pending* in the outbox — held, never pushed, never failed.
        engine.pushGate = { [weak blobs] table, uuid in
            blobs?.isRecordPushable(table: table, uuid: uuid) ?? true
        }
        blobs.onUploadsSettled = { [weak self] in
            guard let self else { return }
            self.engine?.resetBackoff()
            Task { await self.syncNow() }
        }
        engine.didApplyRemoteChanges = { [weak self] in self?.onRemoteChanges?() }
        engine.onAccountDeleted = { [weak self] in
            guard let self, let controller = self.controller else { return }
            Task { await controller.handleAccountDeleted() }
        }

        if enrolling {
            do {
                try engine.enroll()
            } catch {
                lastError = "\(error)"
            }
        }
        self.engine = engine
        self.blobStore = blobs
        engineBuildCountForTesting += 1

        let triggers = configuration.makeTriggers(container) + [manual]
        let signals = CompositeHistoryChangeTrigger(triggers).signals()
        triggerTask = Task { [weak self] in
            for await _ in signals {
                guard let self else { return }
                self.scheduleDebouncedSync()
            }
        }

        await syncNow()
    }

    private func stopEngine(releasing: Bool) {
        triggerTask?.cancel()
        triggerTask = nil
        retryTask?.cancel()
        retryTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        if releasing {
            engine = nil
            blobStore = nil
        }
    }

    /// Sign-out's clear, barrier-gated across **both** layers. Both counts are read before either
    /// clear runs: clearing one and refusing the other would leave the device half-signed-out,
    /// and clearing the library while a recording was still queued for upload would destroy bytes
    /// no server has ever held.
    private func clearOnSignOut() {
        stopEngine(releasing: false)
        keptOnSignOut = 0
        guard let container else { return }
        let engine = self.engine ?? makeDetachedEngine(container: container)
        let blobs = self.blobStore

        let unpushedRecords = engine?.state.outbox.count ?? 0
        let undrainedUploads = blobs.map { $0.counted.total } ?? 0
        guard unpushedRecords + undrainedUploads == 0 else {
            keptOnSignOut = unpushedRecords + undrainedUploads
            self.engine = nil
            self.blobStore = nil
            return
        }

        do {
            // The engine's own barrier still runs: this is a re-read, not a substitute for it.
            try engine?.clearSyncedData()
            try blobs?.clearLocalData()
            lastSyncedAt = nil
            counted = OutboxCensus()
            blobPendingCount = 0
        } catch {
            // The count the guard above read is the barrier's own, so this reports what is
            // actually held rather than flooring it: the clear can still fail for a reason that
            // is not the outbox, and a fabricated "1 change" would name work that does not exist.
            // `lastError` is what carries a non-barrier failure.
            keptOnSignOut = engine?.state.outbox.count ?? 0
            lastError = "\(error)"
        }
        self.engine = nil
        self.blobStore = nil
        onRemoteChanges?()
    }

    /// Every synced row, the sync state, the upload queue and the whole recording cache — gone.
    /// Switch and delete only.
    private func discardLocalData() {
        stopEngine(releasing: false)
        guard let container else { return }
        let engine = self.engine ?? makeDetachedEngine(container: container)
        // This clear discards unconditionally, so this is what is actually being destroyed:
        // the whole outbox, refused entries included.
        discardedOnSwitch = engine?.state.outbox.count ?? 0
        try? engine?.clearSyncedData(discardingUnsynced: true)
        try? blobStore?.clearLocalData(discardingUnsynced: true)
        self.engine = nil
        self.blobStore = nil
        lastSyncedAt = nil
        counted = OutboxCensus()
        blobPendingCount = 0
        onRemoteChanges?()
    }

    /// An engine with no account behind it, for the one job that outlives the credentials: wiping
    /// after the controller has already dropped them.
    private func makeDetachedEngine(container: ModelContainer) -> SyncEngine? {
        guard let url = try? configuration.stateFileURL() else { return nil }
        let state = SyncStateFile(url: url)
        return SyncEngine(
            container: container,
            stateFile: state,
            transport: UnreachableTransport(),
            account: DetachedAccount(accountID: state.read().accountID ?? UUID()),
            schema: TranscriptionSyncSchema.schema
        )
    }

    // MARK: - Reacting

    private func publish(_ result: SyncStatus) {
        status = result
        lastError = engine?.lastError ?? blobStore?.lastError
        refreshCounters()
    }

    private func refreshCounters() {
        guard let state = engine?.state else { return }
        lastSyncedAt = state.lastSyncedAt
        counted = state.counted
        blobPendingCount = blobStore.map { $0.counted.total } ?? 0
    }

    // MARK: - Backoff and connectivity

    private func scheduleRetry(after result: SyncStatus) {
        retryTask?.cancel()
        retryTask = nil
        guard case .offline(let delay) = result else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// The clock resets on a network-path change, so a device coming back on Wi-Fi retries at once
    /// rather than at the tail of a five-minute backoff it earned while genuinely offline.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.engine != nil else { return }
                self.engine?.resetBackoff()
                self.blobStore?.resetBackoff()
                await self.syncNow()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.fcttechnologies.TranscriptionStudio.sync.path"))
    }
}

/// The wire, cut. Used where a process needs an engine's local half and must never reach a server.
nonisolated struct UnreachableTransport: SyncTransport {
    func push(schemaVersion: String, records: [PushRecord]) async throws -> [PushVerdict] {
        throw SyncTransportError.connectivity("no account")
    }

    func pull(schemaVersion: String, table: String, cursor: Int64, pageLimit: Int) async throws -> PullEnvelope {
        throw SyncTransportError.connectivity("no account")
    }
}

nonisolated struct DetachedAccount: SyncAccount {
    let accountID: UUID
    func accessToken() async throws -> String { throw SyncTransportError.authRefused("no session") }
    func accessToken(afterRefusalOf refused: String) async throws -> String {
        throw SyncTransportError.authRefused("no session")
    }
}
