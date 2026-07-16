import Foundation

/// Stable per-install identity for the companion presence heartbeat and the claim marker. The
/// identifier is a UUID persisted in `UserDefaults` (stable across launches for this install);
/// the name is a human-readable label for the presence indicator.
enum CompanionDevice {
    private static let idKey = "com.fcttechnologies.TranscriptionStudio.deviceID"

    static var identifier: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: idKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: idKey)
        return fresh
    }

    /// A friendly device name. The heartbeat is Mac-only, so this reads the Mac's computer name;
    /// the Foundation `Host` fallback keeps it defined when built for other platforms.
    static var name: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}
