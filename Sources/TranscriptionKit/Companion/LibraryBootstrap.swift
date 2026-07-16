import Foundation
import Observation
import FCTSync

/// The first-launch "syncing your library…" coordinator. On a fresh install the local store is
/// empty while CloudKit may still be importing an existing library, so showing the bare empty
/// feed reads as "you have nothing" when really the data is a few seconds behind. This gates that
/// first launch on FCTFoundation's shipped ``CloudBootstrapGate`` — reused, not reimplemented —
/// revealing the feed the moment the initial import resolves (or a short bound elapses).
///
/// It only ever waits on the very first launch (tracked in `UserDefaults`); every later launch
/// already has local data and goes straight to `.ready`. The feed also reveals immediately the
/// instant any session appears (``markReady()``), so a returning user never waits behind the gate.
@MainActor
@Observable
public final class LibraryBootstrap {
    public enum Phase: Equatable, Sendable {
        case idle
        case syncing
        case ready
    }

    public private(set) var phase: Phase = .idle

    private let gate: CloudBootstrapGate
    private var task: Task<Void, Never>?

    private static let didBootstrapKey = "com.fcttechnologies.TranscriptionStudio.didBootstrap"

    /// - Parameter sessionCount: reads the current library size, so the gate can tell a stalled
    ///   import (count unchanged) from a slow-but-live one (rows still arriving).
    public init(sessionCount: @escaping @MainActor () -> Int) {
        let monitor = CloudKitImportMonitor.cloudKit()
        let probe = SessionCountProbe(count: sessionCount)
        // Short bounds — this is a launch nicety, not a data-seeding gate, so the worst case is a
        // brief wait, not a hang.
        let configuration = CloudBootstrapGate.Configuration(
            minimumWait: .seconds(1),
            idleGracePeriod: .seconds(3),
            maximumWait: .seconds(12),
            pollInterval: .seconds(1),
            timeoutMessage: "Sync is taking longer than usual."
        )
        gate = CloudBootstrapGate(monitor: monitor, probe: probe, configuration: configuration)
    }

    /// Begin the first-launch wait if this install hasn't bootstrapped before. Shows `.syncing`
    /// until the initial CloudKit import resolves (or the short bound elapses), then `.ready`.
    public func beginIfNeeded() {
        guard phase == .idle, task == nil else { return }
        guard !UserDefaults.standard.bool(forKey: Self.didBootstrapKey) else {
            phase = .ready
            return
        }
        phase = .syncing
        task = Task { [weak self] in
            _ = await self?.gate.awaitImportReady()
            self?.finish()
        }
    }

    /// Reveal immediately — data already arrived (a session showed up), so there's nothing to wait
    /// for. Cancels the in-flight gate wait.
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

/// Bridges the app's session count into the gate's ``BootstrapProgressProbing`` seam.
@MainActor
private struct SessionCountProbe: BootstrapProgressProbing {
    let count: @MainActor () -> Int
    func progressFingerprint() -> AnyHashable { count() }
}
