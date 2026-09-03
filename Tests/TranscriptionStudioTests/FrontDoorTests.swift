import Foundation
import Testing
@testable import TranscriptionStudio

/// A mutable answer a test can change between routes, without capturing a `var` in an escaping
/// closure.
@MainActor
private final class RestoreStub {
    var answer: Bool
    private(set) var calls = 0
    /// Set to gate the answer on a signal the test controls, rather than on a sleep racing the work.
    var gate: (() async -> Void)?

    init(answer: Bool) { self.answer = answer }

    func restore() async -> Bool {
        calls += 1
        await gate?()
        return answer
    }
}

/// The engine's per-account restore marker, as a value a test can change between routes.
@MainActor
private final class MarkerStub {
    var accounts: Set<UUID>
    init(accounts: Set<UUID>) { self.accounts = accounts }
}

/// The front door's routing: which stage a launch lands on, and — the whole reason it exists — that
/// no path through it reaches the app's own surfaces with the account's first pull unanswered.
@MainActor
struct FrontDoorRoutingTests {
    /// A suite of its own per test: the real one decides what the next launch of the shipping app
    /// does, and a test must never write into it.
    private func scratch(_ name: String) -> UserDefaults { UserDefaults(suiteName: name)! }

    private func makeDoor(
        defaults: UserDefaults,
        accountID: UUID,
        stub: RestoreStub,
        pulledAccounts: Set<UUID> = [],
        speechModelInstalled: Bool = true
    ) -> TranscriptionFrontDoor {
        let door = TranscriptionFrontDoor(defaults: defaults)
        door.session = { (true, accountID) }
        door.restoreAccountData = { await stub.restore() }
        door.hasCompletedFirstPull = { pulledAccounts.contains($0) }
        door.isSpeechModelInstalled = { speechModelInstalled }
        return door
    }

    @Test func aDeviceThatHasNeverPulledThisAccountRestoresBeforeTheApp() async {
        let name = "ts-frontdoor-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let accountID = UUID()

        let door = makeDoor(defaults: defaults, accountID: accountID, stub: RestoreStub(answer: true))
        #expect(door.entry == .restore)
        await door.start()

        #expect(door.stage == .ready)
    }

    @Test func aDeviceThatAlreadyRestoredThisAccountDoesNotPullAgain() async {
        let name = "ts-frontdoor-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let accountID = UUID()

        let stub = RestoreStub(answer: true)
        let door = makeDoor(defaults: defaults, accountID: accountID, stub: stub,
                            pulledAccounts: [accountID])
        #expect(door.entry == .resume)
        await door.start()

        #expect(door.stage == .ready)
        #expect(stub.calls == 0)
    }

    /// The failure a per-install flag has and a per-account one does not: the second account to
    /// sign in on this device has never had its library pulled here, and an install-wide
    /// "already bootstrapped" would send it straight to an empty feed. The engine's marker is per
    /// account, and the door has to ask it about the account actually signed in.
    @Test func aSecondAccountOnTheSameDeviceStillRestores() {
        let name = "ts-frontdoor-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let door = makeDoor(defaults: defaults, accountID: UUID(), stub: RestoreStub(answer: true),
                            pulledAccounts: [UUID()])
        #expect(door.entry == .restore)
    }

    @Test func aPullThatCouldNotCompleteSaysSoInsteadOfShowingAnEmptyLibrary() async {
        let name = "ts-frontdoor-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let accountID = UUID()

        let door = makeDoor(defaults: defaults, accountID: accountID, stub: RestoreStub(answer: false))
        await door.start()

        guard case .restoreFailed = door.stage else {
            Issue.record("a refused pull must surface its refusal, not the app — got \(door.stage)")
            return
        }
    }

    @Test func retryAfterAFailedPullReachesTheApp() async {
        let name = "ts-frontdoor-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let stub = RestoreStub(answer: false)
        let door = makeDoor(defaults: defaults, accountID: UUID(), stub: stub)
        await door.start()
        guard case .restoreFailed = door.stage else {
            Issue.record("expected a refusal first — got \(door.stage)")
            return
        }

        stub.answer = true
        await door.retry()
        #expect(door.stage == .ready)
        #expect(stub.calls == 2)
    }

    /// A wipe drops the engine's marker with the rows it described, so the door routes from the
    /// top again and restores rather than resuming onto a store nothing filled.
    @Test func clearingThisDevicesCopyRoutesTheNextLaunchBackThroughTheRestore() async {
        let name = "ts-frontdoor-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let accountID = UUID()

        let pulled = MarkerStub(accounts: [accountID])
        let door = makeDoor(defaults: defaults, accountID: accountID, stub: RestoreStub(answer: true))
        door.hasCompletedFirstPull = { pulled.accounts.contains($0) }
        #expect(door.entry == .resume)

        // The clear that wipes the rows is the same one that drops the marker.
        pulled.accounts = []
        door.localDataCleared()

        #expect(door.stage == .launching)
        #expect(door.entry == .restore)
    }

    /// A restore started before a sign-out must not land afterwards and push the window back into
    /// the app the user has just left.
    @Test func aRestoreThatLandsAfterAClearDoesNotReopenTheApp() async {
        let name = "ts-frontdoor-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let stub = RestoreStub(answer: true)
        let signal = AsyncStream<Void>.makeStream()
        let stream = signal.stream
        stub.gate = { for await _ in stream { break } }

        let door = makeDoor(defaults: defaults, accountID: UUID(), stub: stub)
        let launch = Task { await door.start() }
        while door.stage != .restoring { await Task.yield() }

        door.localDataCleared()
        signal.continuation.yield()
        signal.continuation.finish()
        await launch.value

        #expect(door.stage == .launching)
    }
}


/// The speech-model offer: the one screen that names the ~1.6 GB before it is spent.
///
/// Its whole risk is being in the way. The offer has to appear when the model is genuinely
/// missing, disappear the moment it is answered, and never stand between a returning user and
/// their library — so each of those is a test rather than a reading of the routing.
@MainActor
struct SpeechModelOfferRoutingTests {
    private func scratch(_ name: String) -> UserDefaults { UserDefaults(suiteName: name)! }

    private func makeDoor(defaults: UserDefaults,
                          accountID: UUID = UUID(),
                          restored: Bool,
                          modelInstalled: Bool) -> TranscriptionFrontDoor {
        let door = TranscriptionFrontDoor(defaults: defaults)
        door.session = { (true, accountID) }
        door.restoreAccountData = { true }
        door.hasCompletedFirstPull = { _ in restored }
        door.isSpeechModelInstalled = { modelInstalled }
        return door
    }

    @Test func aMissingModelIsOfferedAfterTheLibraryLands() async {
        let name = "ts-offer-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let door = makeDoor(defaults: defaults, restored: false, modelInstalled: false)
        await door.start()

        #expect(door.stage == .offerSpeechModel)
    }

    @Test func aModelAlreadyOnDiskIsNeverOffered() async {
        let name = "ts-offer-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let door = makeDoor(defaults: defaults, restored: false, modelInstalled: true)
        await door.start()

        #expect(door.stage == .ready)
        #expect(!SpeechModelOfferState.wasOffered(in: defaults))
    }

    /// Answering is what retires the offer, either way — the point of recording the answer rather
    /// than the outcome is that "Later" has to stick just as hard as "Download Now".
    @Test func answeringRetiresTheOfferForGood() async {
        let name = "ts-offer-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let accountID = UUID()

        let first = makeDoor(defaults: defaults, accountID: accountID,
                             restored: false, modelInstalled: false)
        await first.start()
        #expect(first.stage == .offerSpeechModel)
        first.speechModelOfferAnswered()
        #expect(first.stage == .ready)

        // The model is still missing — declining did not install anything — and the next launch
        // must still go straight through.
        let second = makeDoor(defaults: defaults, accountID: accountID,
                              restored: true, modelInstalled: false)
        await second.start()
        #expect(second.stage == .ready)
    }

    /// The offer sits after the library, never in front of it: a failed pull still shows its own
    /// refusal, because a missing model is not a reason to stop saying the library never arrived.
    @Test func aFailedPullStillReportsTheRefusalRatherThanTheOffer() async {
        let name = "ts-offer-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let door = TranscriptionFrontDoor(defaults: defaults)
        door.session = { (true, UUID()) }
        door.restoreAccountData = { false }
        door.isSpeechModelInstalled = { false }
        await door.start()

        guard case .restoreFailed = door.stage else {
            Issue.record("expected the restore refusal, got \(door.stage)")
            return
        }
    }

    /// A returning device with the model already answered for takes the same one-step path it
    /// always did.
    @Test func aResumeWithNothingToAskReachesTheAppDirectly() async {
        let name = "ts-offer-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }
        SpeechModelOfferState.markOffered(in: defaults)

        let door = makeDoor(defaults: defaults, restored: true, modelInstalled: false)
        await door.start()

        #expect(door.stage == .ready)
    }
}
