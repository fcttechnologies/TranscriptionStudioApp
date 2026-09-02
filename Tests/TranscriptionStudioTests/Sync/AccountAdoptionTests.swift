import FCTAccount
import FCTAccountProfile
import FCTServerSync
import FCTServerSyncTesting
import Foundation
import SwiftData
import Testing

@testable import TranscriptionStudio

/// Transcription Studio's adoption of the shared account: that the fragment it composed into its
/// own schema really rides its own wire, and that the gate its root builds is reached after
/// sign-in through this app's driver rather than a hypothetical one.
///
/// What is proven in `FCTAccountProfile` and deliberately not repeated: the stage rule itself, the
/// completion order, and the funnel.
@Suite("The FCT account, adopted", .serialized)
struct AccountAdoptionTests {

    /// The gate's wait begins before the engine exists — the account's event stream builds the
    /// engine and races the view that starts waiting — so the cycle it asks for has to be the one
    /// that actually lands. A driver returning "no engine" immediately would settle the attempt
    /// against a pull that never ran and show the unreachable surface on a healthy first launch.
    @Test @MainActor
    func theGateAsksOnceTheFirstPullLandsAfterSignIn() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }
        let coordinator = AccountOnboardingCoordinator(
            stateFile: try #require(device.sync.stateFile),
            sync: { _ = await device.sync.restoreAccountData() },
            trusted: AccountTrusted(account: FakeAccount(accountID: device.accountID))
        )

        #expect(coordinator.stage(hasRow: false) == .waiting, "nothing is asked before the pull answers")

        async let pull: Void = coordinator.waitForPull()
        await device.enroll()
        await pull

        #expect(coordinator.stage(hasRow: false) == .onboarding, "the server answered and the account is new")
        #expect(coordinator.stage(hasRow: true) == .app, "a row on file opens the app instead")
    }

    /// The name Apple carried on the authorization survives the event, which is the only place it
    /// is ever offered — the gate prefills from this and from nothing else.
    @Test @MainActor
    func enrollingKeepsTheAppleName() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }
        var name = PersonNameComponents()
        name.givenName = "Fernando"
        name.familyName = "Cortez"

        await device.sync.handle(.enrolled(device.accountID, appleFullName: name))

        #expect(device.sync.appleFullName?.givenName == "Fernando")
        #expect(device.sync.appleFullName?.familyName == "Cortez")
    }

    /// The two account tables ride this app's own schema over its own wire: one device writes
    /// them, a second device on the same account pulls them back under the fixed uuids the server
    /// pins.
    @Test @MainActor
    func theAccountFragmentRoundTripsToASecondDevice() async throws {
        let server = FakeSyncServer()
        let accountID = UUID()
        let author = try BootstrapDevice(server: server, accountID: accountID)
        defer { author.tearDown() }
        let reader = try BootstrapDevice(server: server, accountID: accountID)
        defer { reader.tearDown() }

        let authored = author.container.mainContext
        authored.insert(AccountOnboardingRecord(completedIn: TranscriptionSyncSchema.postgresSchema))
        authored.insert(AccountProfileField(kind: .givenName, value: "Fernando"))
        authored.insert(AccountProfileField(kind: .familyName, value: "Cortez"))
        try authored.save()
        await author.enroll()
        await author.sync.syncNow(.full)

        await reader.enroll()
        await reader.sync.syncNow(.full)

        let read = reader.container.mainContext
        let onboarding = try read.fetch(FetchDescriptor<AccountOnboardingRecord>())
        #expect(onboarding.count == 1)
        #expect(onboarding.first?.id == AccountSchema.onboardingID)
        #expect(onboarding.first?.completedIn == TranscriptionSyncSchema.postgresSchema)

        let given = try #require(try AccountProfileField.fetch(.givenName, in: read))
        #expect(given.value == "Fernando")
        #expect(given.id == AccountProfileField.Kind.givenName.id)
        let family = try #require(try AccountProfileField.fetch(.familyName, in: read))
        #expect(family.value == "Cortez")
        #expect(family.id == AccountProfileField.Kind.familyName.id)
    }
}
