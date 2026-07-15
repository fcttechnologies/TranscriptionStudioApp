import Foundation
import OSLog
import SwiftData

/// The shared model container. Tests get an in-memory store; the app tries CloudKit-synced
/// persistence first, then falls back down a robust ladder so data still survives even when
/// iCloud isn't provisioned yet. The CloudKit container is inferred from the app's
/// entitlements (`iCloud.com.fcttechnologies.TranscriptionStudio`, shared by the Mac and iOS
/// targets — that shared id is what makes Mac↔iOS sync).
public enum AppModelContainer {
    public static let schema = Schema([TranscriptSession.self, StoredSegment.self])

    public static let shared: ModelContainer = {
        if isRunningTests {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [config])
        }
        // 1. CloudKit-synced persistent store — the primary path. `.automatic` uses the
        //    container declared in the entitlements. Syncs across the person's devices.
        do {
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            let container = try ModelContainer(for: schema, configurations: [config])
            Logger.persistence.info("Model store: CloudKit-synced (container from entitlements)")
            return container
        } catch {
            Logger.persistence.error("CloudKit store failed (\(error, privacy: .public)); falling back to local persistent")
        }
        // 2. Local persistent store (no sync) — data still persists on-device if iCloud
        //    isn't provisioned. Same default on-disk URL, so nothing is lost.
        do {
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            Logger.persistence.info("Model store: local persistent (no CloudKit sync)")
            return container
        } catch {
            Logger.persistence.error("Local persistent store failed (\(error, privacy: .public)); falling back to in-memory")
        }
        // 3. In-memory only — last resort; data will not persist across launches.
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        Logger.persistence.warning("Model store: in-memory only (data will not persist)")
        return try! ModelContainer(for: schema, configurations: [config])
    }()

    /// Covers XCTest and Swift Testing hosts.
    public static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] == "1"
    }
}
