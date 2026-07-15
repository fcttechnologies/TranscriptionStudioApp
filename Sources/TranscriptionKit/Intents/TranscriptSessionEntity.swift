import Foundation
import AppIntents
import CoreSpotlight
import OSLog
import SwiftData
import FCTEntities

/// A saved transcription session, exposed to Siri, Shortcuts, Spotlight, and Apple
/// Intelligence. `IndexedEntity` so sessions surface in Spotlight and Apple Intelligence
/// search; the string query resolves by id and by free-text over both the title *and* the
/// full transcript, so "search my transcripts for the budget" finds a session by its content.
public struct TranscriptSessionEntity: IndexedEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Transcript", comment: "The AppEntity type name for a saved session"),
            numericFormat: "\(placeholder: .int) transcripts"
        )
    }

    /// Stable identity: the session's UUID as a string (Spotlight + Shortcuts want a string id).
    public var id: String

    @Property(title: "Title", indexingKey: \.title)
    public var title: String

    @Property(title: "Date", indexingKey: \.contentCreationDate)
    public var date: Date

    @Property(title: "Kind")
    public var kindLabel: String

    /// Length in seconds.
    @Property(title: "Duration")
    public var duration: TimeInterval

    /// A short preview of the transcript for Spotlight's content description (the full text
    /// stays in SwiftData and is what the string query searches).
    @Property(title: "Transcript", indexingKey: \.contentDescription)
    public var textPreview: String

    public init(id: String, title: String, date: Date, kindLabel: String,
                duration: TimeInterval, textPreview: String) {
        self.id = id
        self.title = title
        self.date = date
        self.kindLabel = kindLabel
        self.duration = duration
        self.textPreview = textPreview
    }

    public var displayRepresentation: DisplayRepresentation {
        var parts = [kindLabel, date.formatted(date: .abbreviated, time: .shortened)]
        if duration > 0 { parts.append(TimeFormat.clock(duration)) }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(parts.joined(separator: " · "))",
            image: .init(systemName: "waveform")
        )
    }

    public static let defaultQuery = TranscriptSessionEntityQuery()
}

extension TranscriptSessionEntity {
    /// Build an entity from a stored session. Reads SwiftData properties, so it runs where the
    /// session's context lives (the main actor for the shared container).
    @MainActor
    init(_ session: TranscriptSession) {
        self.init(id: session.id.uuidString,
                  title: session.title,
                  date: session.createdAt,
                  kindLabel: SessionKindStyle.label(session.kind),
                  duration: session.duration,
                  textPreview: String(session.fullText.prefix(280)))
    }
}

/// Resolves session entities for Siri/Shortcuts/Spotlight: by id, and by free-text search
/// over title + full transcript. Backed by the shared SwiftData store (in-memory under tests).
public struct TranscriptSessionEntityQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [TranscriptSessionEntity] {
        let ids = identifiers.compactMap(UUID.init(uuidString:))
        return await TranscriptSessionStore.entities(withIDs: ids)
    }

    public func entities(matching string: String) async throws -> [TranscriptSessionEntity] {
        await TranscriptSessionStore.entities(matching: string)
    }

    public func suggestedEntities() async throws -> [TranscriptSessionEntity] {
        await TranscriptSessionStore.recentEntities(limit: 12)
    }
}

/// The one place intents, entity queries, and Spotlight indexing read sessions from. Every
/// method takes the container so tests drive it with a fresh in-memory store; production uses
/// `AppModelContainer.shared`. Fetches run on the main actor because the shared container's
/// contexts are main-actor bound, and every method hands back Sendable values (entities /
/// strings) — never the non-Sendable SwiftData model across an actor hop.
@MainActor
public enum TranscriptSessionStore {
    /// Sessions whose title *or* full transcript match the query (case/diacritic-insensitive),
    /// newest first, as entities. An empty query returns the most recent sessions.
    public static func entities(matching query: String,
                                in container: ModelContainer = AppModelContainer.shared)
        -> [TranscriptSessionEntity] {
        matchingSessions(query, in: container).map(TranscriptSessionEntity.init)
    }

    /// Resolve entities by id (order not preserved).
    public static func entities(withIDs ids: [UUID],
                                in container: ModelContainer = AppModelContainer.shared)
        -> [TranscriptSessionEntity] {
        let wanted = Set(ids)
        return allSessions(in: container)
            .filter { wanted.contains($0.id) }
            .map(TranscriptSessionEntity.init)
    }

    public static func recentEntities(limit: Int,
                                      in container: ModelContainer = AppModelContainer.shared)
        -> [TranscriptSessionEntity] {
        Array(allSessions(in: container).prefix(limit)).map(TranscriptSessionEntity.init)
    }

    /// The newest session as an entity paired with its full transcript text (both Sendable).
    public static func latestEntityAndText(in container: ModelContainer = AppModelContainer.shared)
        -> (entity: TranscriptSessionEntity, fullText: String)? {
        guard let session = allSessions(in: container).first else { return nil }
        return (TranscriptSessionEntity(session), session.fullText)
    }

    /// A specific session as an entity paired with its full transcript text.
    public static func entityAndText(forID id: UUID,
                                     in container: ModelContainer = AppModelContainer.shared)
        -> (entity: TranscriptSessionEntity, fullText: String)? {
        guard let session = allSessions(in: container).first(where: { $0.id == id }) else { return nil }
        return (TranscriptSessionEntity(session), session.fullText)
    }

    /// A specific session rendered in an export format, paired with its title (for the
    /// filename). Computed here on the main actor from the stored segments — the raw
    /// SwiftData model never crosses back out, only the rendered (Sendable) string.
    public static func exportedText(forID id: UUID, as format: TranscriptExport.Format,
                                    in container: ModelContainer = AppModelContainer.shared)
        -> (title: String, text: String)? {
        guard let session = allSessions(in: container).first(where: { $0.id == id }) else { return nil }
        return renderedExport(session, as: format)
    }

    /// The newest session rendered in an export format, paired with its title.
    public static func latestExportedText(as format: TranscriptExport.Format,
                                          in container: ModelContainer = AppModelContainer.shared)
        -> (title: String, text: String)? {
        guard let session = allSessions(in: container).first else { return nil }
        return renderedExport(session, as: format)
    }

    private static func renderedExport(_ session: TranscriptSession,
                                       as format: TranscriptExport.Format) -> (title: String, text: String) {
        let items = TranscriptExport.items(from: session)
        return (session.title, TranscriptExport.render(items, as: format, title: session.title))
    }

    // MARK: Fetch

    /// Cap on a single Siri/Spotlight read-path fetch — a defensive limit so a large library
    /// never loads unbounded rows onto the main actor in one query.
    private static let maxFetchedSessions = 500

    static func matchingSessions(_ query: String, in container: ModelContainer) -> [TranscriptSession] {
        let all = allSessions(in: container)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.fullText.localizedCaseInsensitiveContains(needle)
        }
    }

    private static func allSessions(in container: ModelContainer) -> [TranscriptSession] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<TranscriptSession>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = maxFetchedSessions
        return (try? context.fetch(descriptor)) ?? []
    }
}

/// Keeps the Spotlight/Apple-Intelligence index in step with the library. Best-effort: index
/// failures never block the app, and indexing is skipped under tests. Never logs transcript
/// content — only counts. Donates through a stable, app-owned named index (never the system
/// default — only a named index carries a data-protection class); every session is eligible
/// for the index, so no `DonationGating` policy is needed here.
@MainActor
public enum TranscriptSpotlightIndex {
    /// The stable, app-owned named index. Never rename without a migration plan for whatever
    /// this index already holds on-device (see `Docs/Migration/TranscriptionStudio.md`).
    public static let indexName = "TranscriptionStudioSessions"
    private static let donator = EntityDonator(indexName: indexName)

    /// Index (or refresh) one session.
    public static func index(_ session: TranscriptSession) {
        guard !AppModelContainer.isRunningTests else { return }
        let entity = TranscriptSessionEntity(session)
        Task {
            do {
                try await donator.donate([entity])
            } catch {
                Logger.persistence.error("Spotlight index failed: \(error, privacy: .public)")
            }
        }
    }

    /// Remove a session from the index (on delete).
    public static func deindex(id: UUID) {
        guard !AppModelContainer.isRunningTests else { return }
        let identifier = id.uuidString
        Task {
            do {
                try await donator.remove([identifier], ofType: TranscriptSessionEntity.self)
            } catch {
                Logger.persistence.error("Spotlight deindex failed: \(error, privacy: .public)")
            }
        }
    }

    /// Reindex the whole library into the named index — called on launch so external/seeded
    /// changes are covered. Also sweeps any entries the pre-migration indexer left in the
    /// system default index (best-effort, one-time — the default index holds nothing once
    /// every session has been through this path once).
    public static func reindexAll(in container: ModelContainer = AppModelContainer.shared) {
        guard !AppModelContainer.isRunningTests else { return }
        let entities = TranscriptSessionStore.recentEntities(limit: .max, in: container)
        guard !entities.isEmpty else { return }
        Task {
            try? await CSSearchableIndex.default().deleteAppEntities(
                identifiedBy: entities.map(\.id), ofType: TranscriptSessionEntity.self)
            do {
                try await donator.reindex(entities)
                Logger.persistence.info("Spotlight reindex: \(entities.count, privacy: .public) sessions")
            } catch {
                Logger.persistence.error("Spotlight reindex failed: \(error, privacy: .public)")
            }
        }
    }
}
