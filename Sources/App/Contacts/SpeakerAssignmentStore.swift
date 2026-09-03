import FCTMetrics
import Foundation
import SwiftData

/// Reads and writes speaker→contact bindings for a session, keeping the Spotlight index in step so a
/// bound name becomes searchable (Siri name resolution). Main-actor because it touches `@Model`
/// objects; every write reindexes the session so its `keywords` reflect the current bindings.
@MainActor
enum SpeakerAssignmentStore {
    /// Bind (or rebind) `slot` in `session` to a contact — one assignment per slot (upsert).
    @discardableResult
    static func assign(slot: Int, contactIdentifier: String, displayName: String,
                              to session: TranscriptSession, in context: ModelContext) -> SpeakerAssignment {
        Diag.count(TranscriptionCounter.speakersNamed)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = (session.speakerAssignments ?? []).first(where: { $0.speakerSlot == slot }) {
            existing.contactIdentifier = contactIdentifier
            existing.displayName = name
            try? context.save()
            TranscriptSpotlightIndex.index(session)
            return existing
        }
        let assignment = SpeakerAssignment(speakerSlot: slot, contactIdentifier: contactIdentifier, displayName: name)
        context.insert(assignment)
        assignment.session = session
        try? context.save()
        TranscriptSpotlightIndex.index(session)
        return assignment
    }

    /// Remove the binding for `slot`, if any.
    static func clear(slot: Int, from session: TranscriptSession, in context: ModelContext) {
        let matches = (session.speakerAssignments ?? []).filter { $0.speakerSlot == slot }
        guard !matches.isEmpty else { return }
        matches.forEach(context.delete)
        try? context.save()
        TranscriptSpotlightIndex.index(session)
    }

    /// slot → bound display name, for speaker labels and pickers.
    static func nameBySlot(for session: TranscriptSession) -> [Int: String] {
        (session.speakerAssignments ?? []).reduce(into: [:]) { result, assignment in
            result[assignment.speakerSlot] = assignment.displayName
        }
    }
}

/// The distinct set of person names associated with a session — bound speaker names first, then the
/// extracted mentioned people — folded into the Spotlight index's `keywords` so a name query
/// ("what did Sergio decide") matches the session even when the raw transcript only said
/// "Speaker 2". Pure over the model, directly testable.
enum SessionPeople {
    static func names(for session: TranscriptSession) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            result.append(trimmed)
        }
        (session.speakerAssignments ?? []).forEach { add($0.displayName) }
        (session.people ?? []).forEach { add($0.name) }
        return result
    }
}
