import Foundation
import OSLog
import SwiftData

/// The shared model container: local store under Application Support, in-memory under
/// tests. (No CloudKit yet — the schema stays CloudKit-ready so sync can switch on
/// without a migration.)
public enum AppModelContainer {
    public static let schema = Schema([TranscriptSession.self, StoredSegment.self])

    public static let shared: ModelContainer = {
        if isRunningTests {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [config])
        }
        do {
            let config = ModelConfiguration()
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            Logger.persistence.error("Persistent store failed (\(error, privacy: .public)); falling back to in-memory")
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [config])
        }
    }()

    /// Covers XCTest and Swift Testing hosts.
    public static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] == "1"
    }
}
