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
        stub: RestoreStub
    ) -> TranscriptionFrontDoor {
        let door = TranscriptionFrontDoor(defaults: defaults)
        door.session = { (true, accountID) }
        door.restoreAccountData = { await stub.restore() }
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
        #expect(LibraryRestoreState.hasRestored(accountID: accountID, in: defaults))
    }

    @Test func aDeviceThatAlreadyRestoredThisAccountDoesNotPullAgain() async {
        let name = "ts-frontdoor-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let accountID = UUID()
        LibraryRestoreState.markRestored(accountID: accountID, in: defaults)

        let stub = RestoreStub(answer: true)
        let door = makeDoor(defaults: defaults, accountID: accountID, stub: stub)
        #expect(door.entry == .resume)
        await door.start()

        #expect(door.stage == .ready)
        #expect(stub.calls == 0)
    }

    /// The failure a per-install flag has and a per-account one does not: the second account to
    /// sign in on this device has never had its library pulled here, and an install-wide
    /// "already bootstrapped" would send it straight to an empty feed.
    @Test func aSecondAccountOnTheSameDeviceStillRestores() {
        let name = "ts-frontdoor-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }
        LibraryRestoreState.markRestored(accountID: UUID(), in: defaults)

        let door = makeDoor(defaults: defaults, accountID: UUID(), stub: RestoreStub(answer: true))
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
        // And it must not be remembered as restored, or the next launch would resume onto a store
        // nothing ever filled.
        #expect(!LibraryRestoreState.hasRestored(accountID: accountID, in: defaults))
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

    @Test func clearingThisDevicesCopyForgetsThatItEverRestored() async {
        let name = "ts-frontdoor-\(UUID().uuidString)"
        let defaults = scratch(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let accountID = UUID()

        let door = makeDoor(defaults: defaults, accountID: accountID, stub: RestoreStub(answer: true))
        await door.start()
        #expect(door.stage == .ready)

        door.localDataCleared()

        #expect(door.stage == .launching)
        #expect(!LibraryRestoreState.hasRestored(accountID: accountID, in: defaults))
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
