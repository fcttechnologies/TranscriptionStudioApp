import Foundation
import Observation

/// The first-launch "restoring your library…" coordinator. On a device that has just signed in,
/// the local store is empty while the sync engine's first pull is still landing, so showing the
/// bare empty feed reads as "you have nothing" when the data is a few seconds behind. This gates
/// that reveal on a caller-supplied restoring probe — the sync bootstrap's own status — and
/// reveals the feed the moment the pull resolves, a session appears, or a short bound elapses.
///
/// It only ever waits on the very first launch of an install (tracked in `UserDefaults`); every
/// later launch already has local data and goes straight to `.ready`. The feed also reveals
/// immediately the instant any session appears (``markReady()``), so a returning user never waits
/// behind the gate, and a device with **no account** never waits at all: there is no engine, so
/// nothing is on its way.
@MainActor
@Observable
public final class LibraryBootstrap {
    public enum Phase: Equatable, Sendable {
        case idle
        case syncing
        case ready
    }

    public private(set) var phase: Phase = .idle

    /// Whether a first restore could still be in flight — the sync bootstrap's `.syncing`. Read
    /// on each poll rather than captured, because the engine is constructed after this object is.
    private let isRestoring: @MainActor () -> Bool
    private let sessionCount: @MainActor () -> Int
    private var task: Task<Void, Never>?

    /// Short bounds — this is a launch nicety, not a data-seeding gate, so the worst case is a
    /// brief wait, not a hang.
    private static let pollInterval = Duration.milliseconds(250)
    /// The engine is constructed and started asynchronously after this gate opens, so a probe read
    /// at t=0 legitimately answers "not restoring" before any cycle has begun. Holding for a beat
    /// is what makes the probe mean something.
    private static let minimumWait = Duration.seconds(1)
    private static let maximumWait = Duration.seconds(12)

    private static let didBootstrapKey = "com.fcttechnologies.TranscriptionStudio.didBootstrap"

    /// - Parameters:
    ///   - sessionCount: the current library size, so the gate can reveal the moment rows arrive.
    ///   - isRestoring: whether the sync engine is mid-cycle. `false` (the default) is the honest
    ///     answer before an account exists and makes the gate a no-op.
    public init(
        sessionCount: @escaping @MainActor () -> Int,
        isRestoring: @escaping @MainActor () -> Bool = { false }
    ) {
        self.sessionCount = sessionCount
        self.isRestoring = isRestoring
    }

    /// Begin the first-launch wait if this install hasn't bootstrapped before. Shows `.syncing`
    /// until the first pull resolves (or rows arrive, or the short bound elapses), then `.ready`.
    public func beginIfNeeded() {
        guard phase == .idle, task == nil else { return }
        guard !UserDefaults.standard.bool(forKey: Self.didBootstrapKey) else {
            phase = .ready
            return
        }
        phase = .syncing
        task = Task { [weak self] in
            let start = ContinuousClock.now
            let floor = start + Self.minimumWait
            let deadline = start + Self.maximumWait
            while !Task.isCancelled, ContinuousClock.now < deadline {
                guard let self else { return }
                if self.sessionCount() > 0 { break }
                if ContinuousClock.now >= floor, !self.isRestoring() { break }
                try? await Task.sleep(for: Self.pollInterval)
            }
            self?.finish()
        }
    }

    /// Reveal immediately — data already arrived (a session showed up), so there's nothing to wait
    /// for. Cancels the in-flight wait.
    public func markReady() {
        guard phase != .ready else { return }
        task?.cancel()
        task = nil
        finish()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.didBootstrapKey)
        task = nil
        phase = .ready
    }
}
