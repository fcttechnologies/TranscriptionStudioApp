import Foundation
import CoreSpotlight
import FoundationModels
import UniformTypeIdentifiers
import OSLog
import FCTIntelligence
// `SpotlightSearchTool` / `SearchSource.coreSpotlight` come from the `_CoreSpotlight_FoundationModels`
// cross-import overlay, which the compiler auto-imports only when BOTH CoreSpotlight and
// FoundationModels are imported together in this file.

/// **Flagship A — Siri semantic Q&A over the whole transcript library.** "What did Sergio and I
/// decide at the last meeting?" resolves to *which* saved transcript (semantic match on the named
/// Spotlight index) and answers *from* its content — one Siri turn, hands-free, entirely on-device.
///
/// The assistant machinery is generalized in `FCTIntelligence.SemanticAssistant` (session + gating +
/// the read-only safety boundary). This type supplies the TS specifics:
/// - the **read-only, own-data-only instructions** (the private-data boundary, testable strings),
/// - a `SpotlightSearchTool` over a `CoreSpotlightSource` whose `searchableIndexDelegate` **hydrates
///   the full transcript text** at query time (the persisted index keeps only a 280-char preview to
///   stay small; the model answering needs far more — the "index for two consumers" split).
///
/// The Spotlight tool is vetted `.readOnly` before it reaches the session (it can read the user's
/// index, never write) — the same "AI reads, user confirms writes" boundary VillainArc ships.
enum TranscriptLibraryAssistant {
    /// The strict read-only, private-data-only system prompt. The boundary phrases here are asserted
    /// by tests, so the safety contract can't silently drift.
    static let instructions = """
        You answer questions about the user's own Transcription Studio library — their saved \
        transcripts of conversations, meetings, and recordings. Use the Spotlight search tool to \
        find the relevant transcript(s) in the user's private on-device index, then answer concisely \
        from what you find.

        Rules:
        - Only use the user's own transcripts. Never invent people, decisions, numbers, or dates.
        - You can only read. You never create, edit, delete, or start anything; if asked to, explain \
        that you can only answer questions and they can make changes in the app.
        - If the search finds nothing relevant, say so plainly and suggest opening the transcript in \
        the library.
        - Keep answers short and specific. Prefer concrete names and quotes from the transcripts.
        """

    /// Whether library Q&A can run right now (Apple Intelligence eligible + enabled).
    static var isAvailable: Bool { SemanticAssistant.currentAvailability().isAvailable }

    /// Build the assistant: TS instructions + a Spotlight RAG tool over the app's named index with
    /// full-text hydration.
    static func makeAssistant() -> SemanticAssistant {
        SemanticAssistant(instructions: instructions, tools: [makeTool()])
    }

    /// Answer a question from the whole library, on-device. Never throws; returns the assistant's
    /// availability/failure reason so the caller degrades to ordinary library search.
    static func ask(_ question: String) async -> Result<String, SemanticAssistant.AskError> {
        await makeAssistant().ask(question)
    }

    // MARK: - Spotlight tool + full-text hydration

    static func makeTool() -> SpotlightSearchTool {
        let source = CoreSpotlightSource(
            searchableIndexDelegate: TranscriptHydrationDelegate(),
            fetchAttributes: [.title, .contentDescription, .keywords]
        )
        return SpotlightSearchTool(configuration: .init(sources: [.coreSpotlight(source)]))
    }

    /// Build a hydrated searchable item for one session: the persisted index only carries a 280-char
    /// preview (kept deliberately small), so at query time the delegate re-provides the item with the
    /// full transcript in `contentDescription` — bounded the same way single-session Q&A bounds its
    /// context, never inflating the persisted index. Pure — directly testable.
    static func hydratedItem(id: String, title: String, fullText: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = SessionIntelligence.trimmedForContext(fullText)
        return CSSearchableItem(
            uniqueIdentifier: id,
            domainIdentifier: TranscriptSpotlightIndex.indexName,
            attributeSet: attributes
        )
    }

    /// Resolve session identifiers to hydrated items by reading the store on the main actor (the
    /// SwiftData contexts are main-actor bound). An id that no longer resolves is dropped.
    @MainActor
    static func hydratedItems(forIDs identifiers: [String]) -> [CSSearchableItem] {
        identifiers.compactMap { idString in
            guard let uuid = UUID(uuidString: idString),
                  let hit = TranscriptSessionStore.entityAndText(forID: uuid) else { return nil }
            return hydratedItem(id: idString, title: hit.entity.title, fullText: hit.fullText)
        }
    }
}

/// The `CoreSpotlightSource` delegate that hydrates full transcript text for the Spotlight search
/// tool. The two reindex methods are required by the protocol; the app's own `TranscriptSpotlightIndex`
/// owns real (re)indexing, so here they simply acknowledge. The item-recovery method is the one that
/// matters — it hands the model the full transcript for the matched session ids.
final class TranscriptHydrationDelegate: NSObject, CSSearchableIndexDelegate {
    func searchableIndex(_ searchableIndex: CSSearchableIndex,
                         reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        acknowledgementHandler()
    }

    func searchableIndex(_ searchableIndex: CSSearchableIndex,
                         reindexSearchableItemsWithIdentifiers identifiers: [String],
                         acknowledgementHandler: @escaping () -> Void) {
        acknowledgementHandler()
    }

    func searchableItems(forIdentifiers identifiers: [String],
                         searchableItemsHandler: @escaping @Sendable ([CSSearchableItem]) -> Void) {
        Task { @MainActor in
            searchableItemsHandler(TranscriptLibraryAssistant.hydratedItems(forIDs: identifiers))
        }
    }
}
