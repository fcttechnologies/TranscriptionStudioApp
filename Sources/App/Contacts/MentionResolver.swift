import Foundation
import FCTContacts

/// One extracted mention paired with the existing contact it resolved to (if any). A `nil` `contact`
/// means either no match or an ambiguous one — the caller offers to pick/save rather than guessing.
struct ResolvedMention: Sendable, Equatable {
    /// The name as extracted from the transcript.
    let name: String
    /// The unambiguously-matched existing contact, or `nil`.
    let contact: ContactCandidate?

    init(name: String, contact: ContactCandidate?) {
        self.name = name
        self.contact = contact
    }

    /// Whether this mention matched an existing contact.
    var isKnown: Bool { contact != nil }
}

/// Resolves a session's extracted `TranscriptPerson` names against the user's contacts (read-only,
/// via the generalized `FCTContacts.ContactResolver`) — the "auto-detected mentions" capability.
/// Pure of any store, so it's testable with a fixture resolver; the app supplies the live
/// `ContactStoreResolver` and the list of extracted names.
struct MentionResolver: Sendable {
    private let resolver: ContactResolver

    init(resolver: ContactResolver) {
        self.resolver = resolver
    }

    /// Convenience over the live CNContactStore-backed resolver.
    init() {
        self.resolver = ContactResolver(provider: ContactStoreResolver())
    }

    /// Whether contacts can be read right now (full or limited access already granted).
    var canResolve: Bool { resolver.authorizationStatus.canRead }

    /// Resolve each mention, de-duplicating names case-insensitively and preserving order. Returns an
    /// empty array (never throws) when access is unavailable — the caller degrades to "no matches".
    func resolve(names: [String]) async -> [ResolvedMention] {
        var seen = Set<String>()
        var out: [ResolvedMention] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            let match = await resolver.resolve(name)
            out.append(ResolvedMention(name: name, contact: match))
        }
        return out
    }
}
