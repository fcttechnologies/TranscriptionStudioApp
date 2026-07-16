import Foundation

/// The App Group shared between the host apps (macOS + iOS) and their Share extensions —
/// the drop-box both sides read/write. The identifier is the single source of truth; the
/// matching entitlement lives in every target's `.entitlements`, and automatic signing
/// (`-allowProvisioningUpdates`) registers it.
public enum AppGroup {
    public static let identifier = "group.com.fcttechnologies.TranscriptionStudio"

    /// The shared container URL, or `nil` when the App Group entitlement isn't present (e.g.
    /// a plain `swift test` process, which has no group container — tests inject their own dir).
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
