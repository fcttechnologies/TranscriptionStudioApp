import Foundation
import OSLog
import SwiftData

/// The shared model container. Tests get an in-memory store; the app tries CloudKit-synced
/// persistence first, then falls back down a robust ladder so data still survives even when
/// iCloud isn't provisioned yet. The CloudKit container is inferred from the app's
/// entitlements (`iCloud.com.fcttechnologies.TranscriptionStudio`, shared by the Mac and iOS
/// targets — that shared id is what makes Mac↔iOS sync).
public enum AppModelContainer {
    public static let schema = Schema([
        TranscriptSession.self, StoredSegment.self, MacPresence.self,
        TranscriptDecision.self, TranscriptActionItem.self, TranscriptEvent.self,
        TranscriptPerson.self, TranscriptPlace.self,
        SpeakerAssignment.self,
    ])

    public static let shared: ModelContainer = {
        if isRunningTests {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [config])
        }
        // Try CloudKit-synced first (the primary path — `.automatic` uses the container from the
        // entitlements, syncing across devices), then a local persistent store (data still
        // survives on-device if iCloud isn't provisioned). Returns nil only if BOTH fail.
        func tryPersistent() -> ModelContainer? {
            do {
                let c = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)])
                Logger.persistence.info("Model store: CloudKit-synced (container from entitlements)")
                return c
            } catch {
                Logger.persistence.error("CloudKit store failed (\(error, privacy: .public)); trying local persistent")
            }
            do {
                let c = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(schema: schema, cloudKitDatabase: .none)])
                Logger.persistence.info("Model store: local persistent (no CloudKit sync)")
                return c
            } catch {
                Logger.persistence.error("Local persistent store failed (\(error, privacy: .public))")
            }
            return nil
        }

        if let container = tryPersistent() { return container }

        // Both persistent opens failed — the on-disk store is almost certainly incompatible
        // (e.g. a pre-schema-change store that can't migrate). The schema is unshipped, so wiping
        // the old local store is acceptable, and fresh durable persistence beats silently running
        // in-memory (which would lose every recording on relaunch).
        let storePath = ModelConfiguration(schema: schema).url.path
        for path in [storePath, storePath + "-wal", storePath + "-shm"] {
            try? FileManager.default.removeItem(atPath: path)
        }
        Logger.persistence.error("Wiped an incompatible store; recreating fresh")
        if let container = tryPersistent() { return container }

        // In-memory only — last resort; data will not persist across launches.
        Logger.persistence.warning("Model store: in-memory only (data will not persist)")
        return try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }()

    /// Covers XCTest and Swift Testing hosts.
    public static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] == "1"
    }
}
