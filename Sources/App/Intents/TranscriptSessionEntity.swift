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
struct TranscriptSessionEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Transcript", comment: "The AppEntity type name for a saved session"),
            numericFormat: "\(placeholder: .int) transcripts"
        )
    }

    /// Stable identity: the session's UUID as a string (Spotlight + Shortcuts want a string id).
    var id: String

    @Property(title: "Title", indexingKey: \.title)
    var title: String

    @Property(title: "Date", indexingKey: \.contentCreationDate)
    var date: Date

    @Property(title: "Kind")
    var kindLabel: String

    /// Length in seconds.
    @Property(title: "Duration")
    var duration: TimeInterval

    /// A short preview of the transcript for Spotlight's content description (the full text
    /// stays in SwiftData and is what the string query searches).
    @Property(title: "Transcript", indexingKey: \.contentDescription)
    var textPreview: String

    /// Free-text hooks indexed as Spotlight `keywords` so a query resolves to this session beyond
    /// its title/transcript: person names (bound speaker contacts + extracted mentions) so a name
    /// query matches even when the raw transcript only labeled "Speaker N", plus the recording
    /// place name so "the meeting at the office" recalls it. See `SessionKeywords`.
    @Property(title: "Keywords", indexingKey: \.keywords)
    var keywords: [String]

    init(id: String, title: String, date: Date, kindLabel: String,
                duration: TimeInterval, textPreview: String, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.date = date
        self.kindLabel = kindLabel
        self.duration = duration
        self.textPreview = textPreview
        self.keywords = keywords
    }

    var displayRepresentation: DisplayRepresentation {
        var parts = [kindLabel, date.formatted(date: .abbreviated, time: .shortened)]
        if duration > 0 { parts.append(TimeFormat.clock(duration)) }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(parts.joined(separator: " · "))",
            image: .init(systemName: "waveform")
        )
    }

    static let defaultQuery = TranscriptSessionEntityQuery()
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
                  textPreview: String(session.fullText.prefix(280)),
                  keywords: SessionKeywords.values(for: session))
    }
}

/// The session's Spotlight `keywords`: the person names (`SessionPeople`) plus the opt-in
/// recording place name, deduplicated case-insensitively. Pure over the model, directly testable.
/// Folding the place in here (rather than a second `@Property` on `\.keywords`, which one
/// property must own) is what makes a place query resolve the session through the same index path
/// people names already use.
enum SessionKeywords {
    static func values(for session: TranscriptSession) -> [String] {
        var result = SessionPeople.names(for: session)
        if let place = session.locationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !place.isEmpty,
           !result.contains(where: { $0.caseInsensitiveCompare(place) == .orderedSame }) {
            result.append(place)
        }
        return result
    }
}

/// Resolves session entities for Siri/Shortcuts/Spotlight: by id, and by free-text search
/// over title + full transcript. Backed by the shared SwiftData store (in-memory under tests).
struct TranscriptSessionEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [String]) async throws -> [TranscriptSessionEntity] {
        let ids = identifiers.compactMap(UUID.init(uuidString:))
        return await TranscriptSessionStore.entities(withIDs: ids)
    }

    func entities(matching string: String) async throws -> [TranscriptSessionEntity] {
        await TranscriptSessionStore.entities(matching: string)
    }

    func suggestedEntities() async throws -> [TranscriptSessionEntity] {
        await TranscriptSessionStore.recentEntities(limit: 12)
    }
}

/// The one place intents, entity queries, and Spotlight indexing read sessions from. Every
/// method takes the container so tests drive it with a fresh in-memory store; production uses
/// `AppModelContainer.shared`. Fetches run on the main actor because the shared container's
/// contexts are main-actor bound, and every method hands back Sendable values (entities /
/// strings) — never the non-Sendable SwiftData model across an actor hop.
@MainActor
enum TranscriptSessionStore {
    /// Sessions whose title *or* full transcript match the query (case/diacritic-insensitive),
    /// newest first, as entities. An empty query returns the most recent sessions.
    static func entities(matching query: String,
                                in container: ModelContainer = AppModelContainer.shared)
        -> [TranscriptSessionEntity] {
        matchingSessions(query, in: container).map(TranscriptSessionEntity.init)
    }

    /// Resolve entities by id (order not preserved).
    static func entities(withIDs ids: [UUID],
                                in container: ModelContainer = AppModelContainer.shared)
        -> [TranscriptSessionEntity] {
        let wanted = Set(ids)
        return allSessions(in: container)
            .filter { wanted.contains($0.id) }
            .map(TranscriptSessionEntity.init)
    }

    static func recentEntities(limit: Int,
                                      in container: ModelContainer = AppModelContainer.shared)
        -> [TranscriptSessionEntity] {
        Array(allSessions(in: container).prefix(limit)).map(TranscriptSessionEntity.init)
    }

    /// The newest session as an entity paired with its full transcript text (both Sendable).
    static func latestEntityAndText(in container: ModelContainer = AppModelContainer.shared)
        -> (entity: TranscriptSessionEntity, fullText: String)? {
        guard let session = allSessions(in: container).first else { return nil }
        return (TranscriptSessionEntity(session), session.fullText)
    }

    /// A specific session as an entity paired with its full transcript text.
    static func entityAndText(forID id: UUID,
                                     in container: ModelContainer = AppModelContainer.shared)
        -> (entity: TranscriptSessionEntity, fullText: String)? {
        guard let session = allSessions(in: container).first(where: { $0.id == id }) else { return nil }
        return (TranscriptSessionEntity(session), session.fullText)
    }

    /// A specific session rendered in an export format, paired with its title (for the
    /// filename). Computed here on the main actor from the stored segments — the raw
    /// SwiftData model never crosses back out, only the rendered (Sendable) bytes.
    static func exportedData(forID id: UUID, as format: TranscriptExport.Format,
                                    in container: ModelContainer = AppModelContainer.shared)
        -> (title: String, data: Data)? {
        guard let session = allSessions(in: container).first(where: { $0.id == id }) else { return nil }
        return renderedExport(session, as: format)
    }

    /// The newest session rendered in an export format, paired with its title.
    static func latestExportedData(as format: TranscriptExport.Format,
                                          in container: ModelContainer = AppModelContainer.shared)
        -> (title: String, data: Data)? {
        guard let session = allSessions(in: container).first else { return nil }
        return renderedExport(session, as: format)
    }

    private static func renderedExport(_ session: TranscriptSession,
                                       as format: TranscriptExport.Format) -> (title: String, data: Data) {
        let items = TranscriptExport.items(from: session)
        return (session.title, TranscriptExport.renderData(items, as: format, title: session.title))
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
        // Private sessions are withheld from the entire Siri / Spotlight / App-Intent read-path
        // (`PrivacyGate.isEligibleForAssistant`), filtered in the fetch so the limit is spent on
        // surfaceable rows only.
        var descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { !$0.isPrivate },
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
enum TranscriptSpotlightIndex {
    /// The stable, app-owned named index. Never rename without a migration plan for whatever
    /// this index already holds on-device (see `Docs/Migration/TranscriptionStudio.md`).
    nonisolated static let indexName = "TranscriptionStudioSessions"
    private static let donator = EntityDonator(indexName: indexName)

    /// Index (or refresh) one session. A private session is never indexed — and if it just
    /// became private, its prior entry is removed instead (`PrivacyGate.isEligibleForAssistant`).
    static func index(_ session: TranscriptSession) {
        guard !AppModelContainer.isRunningTests else { return }
        guard PrivacyGate.isEligibleForAssistant(isPrivate: session.isPrivate) else {
            deindex(id: session.id)
            return
        }
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
    static func deindex(id: UUID) {
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
    static func reindexAll(in container: ModelContainer = AppModelContainer.shared) {
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
