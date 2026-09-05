import CoreGraphics
import FCTAccount
import FCTAccountProfile
import FCTBlobSync
import FCTBlobSyncTesting
import FCTServerSync
import FCTServerSyncTesting
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

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

    /// The account's blob store is in this app's push gate: the `avatar_blob` row naming an object
    /// still sitting on this device stays held, so no other device pulls an avatar uuid the object
    /// store cannot serve. A gate wired to this app's own store alone passes every other test in
    /// this file and fails this one.
    @Test @MainActor
    func thePushGateHoldsTheAvatarRowUntilItsObjectLands() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }
        await device.enroll()
        let avatars = try #require(device.sync.accountBlobs, "the account's store is built with the engine")

        await device.objects.setOnline(false)
        let blobID = try avatars.stageAvatar(avatarJPEG())
        let context = device.container.mainContext
        context.insert(AccountProfileField(kind: .avatarBlob, value: blobID.uuidString))
        try context.save()
        await device.sync.syncNow(.full)

        let held = await device.server.rows(in: AccountProfileField.syncTableName)
        #expect(held.isEmpty, "the row is held while its object is still on this device")

        await device.objects.setOnline(true)
        await device.sync.syncNow(.full)

        let pushed = await device.server.value(
            "value",
            of: AccountProfileField.Kind.avatarBlob.id,
            in: AccountProfileField.syncTableName
        )
        #expect(pushed?.stringValue == blobID.uuidString, "and it pushes once the upload lands")
    }

    /// Signing out clears the account's store with this app's own: the avatar's bytes are the
    /// account's data, and a device that is no longer signed in holds none of it.
    @Test @MainActor
    func signingOutClearsTheAccountBlobStore() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }
        await device.enroll()
        let avatars = try #require(device.sync.accountBlobs)

        let blobID = try avatars.stageAvatar(avatarJPEG())
        await device.sync.syncNow(.full)
        #expect(avatars.cachedAvatar(blobID) != nil, "the picked bytes are cached here")
        #expect(avatars.blobs.counted.isDrained, "and the upload landed, so the barrier is clear")

        await device.sync.handle(.signedOut)

        #expect(device.sync.accountBlobs == nil, "the store goes with the session")
        #expect(
            device.accountBlobsOnDisk.cachedAvatar(blobID) == nil,
            "and its cache was cleared, not just dropped from memory"
        )
    }
}

/// Real encoded image bytes: `stageAvatar` decodes what it is handed and refuses anything it
/// cannot read, so a test staging `Data("bytes".utf8)` would prove only that the refusal works.
@MainActor
private func avatarJPEG(side: Int = 64) -> Data {
    // Safety: `data: nil` asks CoreGraphics to own the bitmap, so no caller buffer can dangle.
    let context = unsafe CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let encoded = NSMutableData()
    let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return encoded as Data
}
