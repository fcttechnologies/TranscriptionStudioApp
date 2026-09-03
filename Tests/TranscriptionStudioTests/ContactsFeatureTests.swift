import Testing
import Foundation
import SwiftData
import FCTContacts
@testable import TranscriptionStudio

/// Speaker→contact binding, the person-name set that feeds Siri name resolution, and mention
/// resolution — all the deterministic Contacts logic, without CNContactStore.
@MainActor
struct SpeakerAndPeopleTests {
    private func makeSession() throws -> (ModelContext, TranscriptSession) {
        let container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = TranscriptSession(title: "Sync", kind: .roomRecording)
        context.insert(session)
        try context.save()
        return (context, session)
    }

    @Test func assignBindsASpeakerSlot() throws {
        let (context, session) = try makeSession()
        SpeakerAssignmentStore.assign(slot: 0, contactIdentifier: "abc", displayName: "Sergio Ramos",
                                      to: session, in: context)
        #expect(session.speakerAssignments?.count == 1)
        #expect(SpeakerAssignmentStore.nameBySlot(for: session)[0] == "Sergio Ramos")
    }

    @Test func reassigningTheSameSlotUpsertsRatherThanDuplicates() throws {
        let (context, session) = try makeSession()
        SpeakerAssignmentStore.assign(slot: 0, contactIdentifier: "a", displayName: "Ana Ruiz", to: session, in: context)
        SpeakerAssignmentStore.assign(slot: 0, contactIdentifier: "b", displayName: "Ana Beltran", to: session, in: context)
        #expect(session.speakerAssignments?.count == 1)
        #expect(SpeakerAssignmentStore.nameBySlot(for: session)[0] == "Ana Beltran")
    }

    @Test func clearRemovesABinding() throws {
        let (context, session) = try makeSession()
        SpeakerAssignmentStore.assign(slot: 1, contactIdentifier: "a", displayName: "Sergio", to: session, in: context)
        SpeakerAssignmentStore.clear(slot: 1, from: session, in: context)
        #expect(session.speakerAssignments?.isEmpty == true)
    }

    @Test func assignableSlotsAreDistinctMeFirstExcludingUnknown() throws {
        let (context, session) = try makeSession()
        for (slot, start) in [(-2, 0.0), (0, 1.0), (2, 2.0), (0, 3.0), (-1, 4.0)] {
            let seg = StoredSegment(start: start, end: start + 1, text: "x")
            seg.speakerSlot = slot
            seg.session = session
            context.insert(seg)
        }
        try context.save()
        // -2 (unknown) dropped; distinct; me (-1) first, then ascending.
        #expect(SpeakerLabels.assignableSlots(in: session) == [-1, 0, 2])
        #expect(SpeakerLabels.name(forSlot: -1) == "Me")
        #expect(SpeakerLabels.name(forSlot: 1) == "Speaker 2")
    }

    @Test func sessionPeopleMergesBoundNamesAndMentionsWithoutDuplicates() throws {
        let (context, session) = try makeSession()
        SpeakerAssignmentStore.assign(slot: 0, contactIdentifier: "a", displayName: "Sergio Ramos", to: session, in: context)
        let ana = TranscriptPerson(name: "Ana"); ana.session = session; context.insert(ana)
        let sergioDup = TranscriptPerson(name: "sergio ramos"); sergioDup.session = session; context.insert(sergioDup)
        try context.save()

        let names = SessionPeople.names(for: session)
        // Bound name first, then the distinct mention; the case-insensitive duplicate is dropped.
        #expect(names == ["Sergio Ramos", "Ana"])
    }
}

/// A fixture contact source so mention resolution is testable without CNContactStore.
private struct FixtureResolver: ContactResolving {
    var status: ContactAuthorization = .authorized
    var byName: [String: [ContactCandidate]] = [:]
    var authorizationStatus: ContactAuthorization { status }
    func requestAccess() async -> Bool { status.canRead }
    func candidates(matchingName name: String) async -> [ContactCandidate] {
        status.canRead ? (byName[name] ?? []) : []
    }
    /// Mention resolution never reads the catalog; the whole book is what a dictation vocabulary
    /// asks for, and this fixture answers by name only.
    func allCandidates(limit: Int) async -> [ContactCandidate] { [] }
}

struct MentionResolverTests {
    private let sergio = ContactCandidate(id: "1", givenName: "Sergio", familyName: "Ramos")

    @Test func resolvesKnownAndUnknownMentions() async {
        let resolver = MentionResolver(resolver: ContactResolver(
            provider: FixtureResolver(byName: ["Sergio": [sergio]])))
        let resolved = await resolver.resolve(names: ["Sergio", "Nobody"])
        #expect(resolved.count == 2)
        #expect(resolved.first { $0.name == "Sergio" }?.contact == sergio)
        #expect(resolved.first { $0.name == "Nobody" }?.isKnown == false)
    }

    @Test func deduplicatesMentionNames() async {
        let resolver = MentionResolver(resolver: ContactResolver(
            provider: FixtureResolver(byName: ["Sergio": [sergio]])))
        let resolved = await resolver.resolve(names: ["Sergio", "sergio", "SERGIO"])
        #expect(resolved.count == 1)
    }

    @Test func deniedAccessResolvesNothing() async {
        let resolver = MentionResolver(resolver: ContactResolver(
            provider: FixtureResolver(status: .denied, byName: ["Sergio": [sergio]])))
        let resolved = await resolver.resolve(names: ["Sergio"])
        #expect(resolved.first?.isKnown == false)
    }
}
