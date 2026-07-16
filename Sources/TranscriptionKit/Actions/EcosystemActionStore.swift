import Foundation
import SwiftData

/// A `Sendable` descriptor of one extracted item that can become a Calendar event or a Reminder —
/// enough to disambiguate between several in a Siri/Shortcuts choice, without carrying the
/// non-`Sendable` `@Model` across an actor hop.
public struct EcosystemActionItemRef: Sendable, Equatable {
    public let id: UUID
    /// The primary label (event title / task).
    public let label: String
    /// A secondary detail (a date, an owner) for the disambiguation prompt; empty when none.
    public let detail: String

    public init(id: UUID, label: String, detail: String) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

/// Reads a session's extracted highlights for the ecosystem App Intents, on the main actor (the
/// shared container's contexts are main-actor bound), handing back only `Sendable` descriptors.
@MainActor
public enum EcosystemActionStore {
    /// The session's extracted events, newest-resolved-date first then as-extracted, as choosable refs.
    public static func events(forSessionID id: UUID,
                              in container: ModelContainer = AppModelContainer.shared) -> [EcosystemActionItemRef] {
        guard let session = session(id, in: container) else { return [] }
        return (session.events ?? []).map { event in
            EcosystemActionItemRef(
                id: event.id,
                label: event.title,
                detail: event.date?.formatted(date: .abbreviated, time: .shortened)
                    ?? event.dateText)
        }
    }

    /// The session's extracted action items as choosable refs.
    public static func actionItems(forSessionID id: UUID,
                                   in container: ModelContainer = AppModelContainer.shared) -> [EcosystemActionItemRef] {
        guard let session = session(id, in: container) else { return [] }
        return (session.actionItems ?? []).map { item in
            let detail = [item.owner, item.dueDate?.formatted(date: .abbreviated, time: .omitted) ?? item.dueDateText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return EcosystemActionItemRef(id: item.id, label: item.task, detail: detail)
        }
    }

    private static func session(_ id: UUID, in container: ModelContainer) -> TranscriptSession? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<TranscriptSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
