import Foundation
import SwiftData

/// The Mac companion's presence beacon: while the Mac app runs, it upserts a single
/// ``MacPresence`` row every `interval`, bumping `lastSeen`. That row syncs, and iOS reads it
/// (through ``MacPresenceStatus``) to show "Mac connected" vs "waiting for your Mac".
/// Best-effort and display-only — a failed write never blocks anything, and presence never gates
/// queuing a link.
@MainActor
public final class PresenceHeartbeat {
    private let modelContext: ModelContext
    private let deviceID: String
    private let deviceName: String
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    public init(modelContext: ModelContext, deviceID: String, deviceName: String,
                interval: TimeInterval = 60) {
        self.modelContext = modelContext
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.interval = interval
    }

    public func start() {
        beat()
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.beat()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Upsert this device's presence row (one per device — matched by `deviceIDString`, a plain
    /// attribute; `id` is the record's cross-device name and stays stable across beats).
    private func beat() {
        let deviceID = self.deviceID
        let descriptor = FetchDescriptor<MacPresence>(
            predicate: #Predicate { $0.deviceIDString == deviceID })
        do {
            if let existing = try modelContext.fetch(descriptor).first {
                existing.lastSeen = Date()
                existing.deviceName = deviceName
            } else {
                modelContext.insert(MacPresence(deviceIDString: deviceID, deviceName: deviceName))
            }
            try modelContext.save()
        } catch {
            // Presence is a best-effort indicator; a transient store error just skips this beat.
        }
    }
}
