// The per-session privacy lock's pure decisions: the biometric gate (`PrivacyGate`), the
// assistant-surface exclusion, and — through an in-memory store — that a private session is
// withheld from the `TranscriptSessionStore` read-path Siri/Spotlight/App-Intents share.

import Foundation
import SwiftData
import Testing
@testable import TranscriptionKit

@Suite("Per-session privacy lock")
struct PrivacyLockTests {
    // MARK: Gate decision

    @Test func privateSessionRequiresAuthUnlessAlreadyUnlocked() {
        #expect(PrivacyGate.requiresAuthentication(isPrivate: true))
        #expect(!PrivacyGate.requiresAuthentication(isPrivate: true, alreadyUnlocked: true))
    }

    @Test func nonPrivateSessionNeverRequiresAuth() {
        #expect(!PrivacyGate.requiresAuthentication(isPrivate: false))
        #expect(!PrivacyGate.requiresAuthentication(isPrivate: false, alreadyUnlocked: false))
    }

    @Test func onlyNonPrivateSessionsSurfaceToTheAssistant() {
        #expect(PrivacyGate.isEligibleForAssistant(isPrivate: false))
        #expect(!PrivacyGate.isEligibleForAssistant(isPrivate: true))
    }

    // MARK: Read-path exclusion (the concrete guarantee behind the gate)

    @MainActor
    @Test func privateSessionsAreWithheldFromTheSiriSpotlightReadPath() throws {
        let container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let normal = TranscriptSession(title: "Team standup", kind: .roomRecording)
        normal.fullText = "shared notes"
        let secret = TranscriptSession(title: "Henderson deposition", kind: .roomRecording)
        secret.fullText = "privileged client statement"
        secret.isPrivate = true
        context.insert(normal)
        context.insert(secret)
        try context.save()

        // A recent-list query — what "suggested entities" / relevance draw from.
        let recent = TranscriptSessionStore.recentEntities(limit: 10, in: container)
        #expect(recent.contains { $0.id == normal.id.uuidString })
        #expect(!recent.contains { $0.id == secret.id.uuidString })

        // A content query that WOULD match the private transcript is still withheld.
        let matches = TranscriptSessionStore.entities(matching: "privileged", in: container)
        #expect(matches.isEmpty)

        // The public session is still findable by its own content.
        let publicMatch = TranscriptSessionStore.entities(matching: "shared", in: container)
        #expect(publicMatch.contains { $0.id == normal.id.uuidString })
    }

    // MARK: The gate wired into AppModel.openSession

    /// A denying/approving authenticator that records whether it was asked.
    private final class FakeAuthenticator: BiometricAuthenticating, @unchecked Sendable {
        let result: Bool
        private(set) var wasAsked = false
        init(result: Bool) { self.result = result }
        func authenticate(reason: String) async -> Bool {
            wasAsked = true
            return result
        }
    }

    @MainActor
    @Test func aPrivateSessionOpensOnlyAfterASuccessfulUnlock() async throws {
        let context = ModelContextFactory.makeInMemory()
        let app = AppModel(modelContext: context)
        let session = TranscriptSession(title: "Private", kind: .roomRecording)
        session.isPrivate = true
        context.insert(session)
        try context.save()

        // Denied unlock → the sheet never opens, and the gate did prompt.
        let denier = FakeAuthenticator(result: false)
        app.authenticator = denier
        await app.unlockAndPresent(id: session.id)
        #expect(denier.wasAsked)
        #expect(app.activeSheet == nil)

        // Granted unlock → the transcript opens.
        app.authenticator = FakeAuthenticator(result: true)
        await app.unlockAndPresent(id: session.id)
        #expect(app.activeSheet == .session(session.id))
    }

    @MainActor
    @Test func aNonPrivateSessionOpensSynchronouslyWithoutPrompting() throws {
        let context = ModelContextFactory.makeInMemory()
        let app = AppModel(modelContext: context)
        let session = TranscriptSession(title: "Open", kind: .roomRecording)
        context.insert(session)
        try context.save()

        let authenticator = FakeAuthenticator(result: false)
        app.authenticator = authenticator
        // openSession is synchronous for a non-private session — the sheet is set immediately.
        app.openSession(id: session.id)

        #expect(!authenticator.wasAsked)
        #expect(app.activeSheet == .session(session.id))
    }
}
