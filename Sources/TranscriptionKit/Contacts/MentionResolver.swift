import Foundation
import FCTContacts

/// One extracted mention paired with the existing contact it resolved to (if any). A `nil` `contact`
/// means either no match or an ambiguous one — the caller offers to pick/save rather than guessing.
public struct ResolvedMention: Sendable, Equatable {
    /// The name as extracted from the transcript.
    public let name: String
    /// The unambiguously-matched existing contact, or `nil`.
    public let contact: ContactCandidate?

    public init(name: String, contact: ContactCandidate?) {
        self.name = name
        self.contact = contact
    }

    /// Whether this mention matched an existing contact.
    public var isKnown: Bool { contact != nil }
}

/// Resolves a session's extracted `TranscriptPerson` names against the user's contacts (read-only,
/// via the generalized `FCTContacts.ContactResolver`) — the "auto-detected mentions" capability.
/// Pure of any store, so it's testable with a fixture resolver; the app supplies the live
/// `ContactStoreResolver` and the list of extracted names.
public struct MentionResolver: Sendable {
    private let resolver: ContactResolver

    public init(resolver: ContactResolver) {
        self.resolver = resolver
    }

    /// Convenience over the live CNContactStore-backed resolver.
    public init() {
        self.resolver = ContactResolver(provider: ContactStoreResolver())
    }

    /// Whether contacts can be read right now (full or limited access already granted).
    public var canResolve: Bool { resolver.authorizationStatus.canRead }

    /// Resolve each mention, de-duplicating names case-insensitively and preserving order. Returns an
    /// empty array (never throws) when access is unavailable — the caller degrades to "no matches".
    public func resolve(names: [String]) async -> [ResolvedMention] {
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
