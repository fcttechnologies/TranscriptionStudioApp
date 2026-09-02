import FCTSync
import Foundation
import OSLog
import SwiftData

/// The shared model container, and the app's store *policy* over FCTSync's shared *mechanism*
/// (`AppGroupStoreConfiguration`): the App Group identifier, the store's path inside the group
/// container, and where the sync layer's durable files sit beside it.
///
/// **The store is local-only.** A library follows its owner through the FCT sync layer
/// (`FCTServerSync` + `FCTAccount` + `FCTBlobSync` for the recordings), so exactly one process —
/// the app — runs the engine, and every other process (Share extension, App Intents) opens a
/// plain local handle on the same file. The engine's state lives in the App Group container too,
/// so a process with no engine can still read `SyncFreshness`.
enum AppModelContainer {
    nonisolated static let appGroupID = "group.com.fcttechnologies.TranscriptionStudio"
    /// Nested under the group container's Application Support directory.
    nonisolated static let storeName = "Library/Application Support/TranscriptionStudio.store"

    static var schema: Schema { Schema(versionedSchema: TranscriptionSchemaCurrent.self) }

    nonisolated static var configuration: AppGroupStoreConfiguration {
        AppGroupStoreConfiguration(
            appGroupID: appGroupID,
            storeName: storeName,
            cloudContainerID: nil,
            versionedSchema: TranscriptionSchemaCurrent.self
        )
    }

    /// The sync engine's durable state — outbox, cursors, versions — beside the store.
    nonisolated static func syncStateFileURL() throws -> URL {
        try configuration.storeURL()
            .deletingLastPathComponent()
            .appendingPathComponent("TranscriptionStudio.store.syncstate.json")
    }

    /// The blob layer's durable state (upload/delete outbox, holds) beside the sync state.
    nonisolated static func blobStateFileURL() throws -> URL {
        try configuration.storeURL()
            .deletingLastPathComponent()
            .appendingPathComponent("TranscriptionStudio.store.blobstate.json")
    }

    /// The permanent per-blob local cache: staged recordings on the device that made them, and
    /// fetched fulls on every other one.
    nonisolated static func blobCacheDirectory() throws -> URL {
        try configuration.storeURL()
            .deletingLastPathComponent()
            .appendingPathComponent("BlobCache", isDirectory: true)
    }

    /// The account blob store's durable state. A `BlobStore` binds to one slug at construction and
    /// the account's objects live under `account/`, so the avatar rides a second store beside this
    /// app's — which needs its own state file, or the two overwrite each other's queues.
    nonisolated static func accountBlobStateFileURL() throws -> URL {
        try configuration.storeURL()
            .deletingLastPathComponent()
            .appendingPathComponent("TranscriptionStudio.store.account-blobstate.json")
    }

    /// The account blob cache, beside this app's own for the same reason.
    nonisolated static func accountBlobCacheDirectory() throws -> URL {
        try configuration.storeURL()
            .deletingLastPathComponent()
            .appendingPathComponent("AccountBlobCache", isDirectory: true)
    }

    /// The transaction author stamped on THIS device's own local writes, so the incremental
    /// Spotlight observer can tell them apart from a change the sync applier landed and skip
    /// re-indexing what its inline `TranscriptSpotlightIndex.index`/`deindex` calls already
    /// handled. See `SpotlightIndexObserver` / `SpotlightReindexDecision`.
    static let localAuthorName = "TranscriptionStudio.local"

    /// A fresh context stamped with ``localAuthorName``. Every app-owned background write path
    /// goes through one so its transactions carry the local author. The SwiftUI
    /// `@Environment(\.modelContext)` (main) context is stamped at launch via
    /// ``stampMainContextAuthor()`` (it's main-actor isolated, so it can't be stamped here).
    static func localContext() -> ModelContext {
        let context = ModelContext(shared)
        context.author = localAuthorName
        return context
    }

    /// Stamp the shared container's main context with ``localAuthorName`` so SwiftUI
    /// `@Environment(\.modelContext)` writes (feed delete, detail rename/save) carry the local
    /// author too — called once at app launch. Main-actor isolated (`mainContext` is).
    @MainActor static func stampMainContextAuthor() {
        shared.mainContext.author = localAuthorName
    }

    static let shared: ModelContainer = {
        if isRunningTests {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [config])
        }

        if let container = makeAppGroupContainer() { return container }

        // The on-disk store is almost certainly incompatible (a pre-schema-change store that
        // can't migrate). The schema is unshipped, so wiping it is acceptable, and fresh durable
        // persistence beats silently running in-memory (which would lose every recording on
        // relaunch). Anything unpushed goes with it, which is why this is a last resort and not a
        // ladder rung.
        if let url = try? configuration.storeURL() {
            for path in [url.path, url.path + "-wal", url.path + "-shm"] {
                try? FileManager.default.removeItem(atPath: path)
            }
            Logger.persistence.error("Wiped an incompatible store; recreating fresh")
            if let container = makeAppGroupContainer() { return container }
        }

        // In-memory only — last resort; data will not persist across launches.
        Logger.persistence.warning("Model store: in-memory only (data will not persist)")
        return try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }()

    private static func makeAppGroupContainer() -> ModelContainer? {
        do {
            let config = configuration
            // The store nests under Library/Application Support; FCTSync appends the name and
            // does not create intermediates.
            let directory = try config.storeURL().deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let container = try config.makeContainer(
                migrationPlan: TranscriptionSchemaMigrationPlan.self,
                log: { Logger.persistence.notice("\($0, privacy: .public)") }
            )
            Logger.persistence.info("Model store: App Group, local-only")
            return container
        } catch {
            Logger.persistence.error("App Group store failed (\(error, privacy: .public))")
            return nil
        }
    }

    /// Covers XCTest and Swift Testing hosts.
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] == "1"
    }
}
