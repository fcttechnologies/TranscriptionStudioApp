import Foundation
import Observation

/// A transient, auto-dismissing in-app notice — the feedback layer for status that should be
/// *seen* but never *block*: the speech model preparing/downloading, a permission problem, a
/// failed import. It floats in at the top of the app above the content, sits for a few
/// seconds (or, for a progress notice, until its work resolves), and dismisses itself; an
/// optional inline action makes it tap-through. Ported from JarvisAwake's proven toast layer
/// and adapted to this app's tokens and status classes.
///
/// A value type with no SwiftUI/`Color` dependency, so the whole feedback surface is
/// describable in plain data (the tint is derived per `Style` in the view).
public struct Toast: Identifiable, Equatable {
    /// The severity/intent tier — drives the leading glyph tint and the haptic.
    public enum Style: Sendable { case info, success, warning, error }

    public let id = UUID()
    public let title: String
    public let message: String?
    public let systemImage: String
    public let style: Style
    /// Renders a small spinner in place of the glyph — the "work in flight" look for
    /// loading / preparing / downloading notices.
    public let isProgress: Bool
    /// The trailing action button's label (nil → no button; a body tap still runs `action`).
    public let actionLabel: String?
    /// Run on tap (body or the labelled button); the toast dismisses first. nil → informational only.
    public let action: (@MainActor () -> Void)?
    /// How long it sits before auto-dismissing. nil → sticky: it stays until dismissed or
    /// updated (progress notices resolve through `ToastCenter.dismiss(dedupKey:)`).
    public let duration: Duration?
    /// Collapses re-raises of the "same" notice while one is still showing/queued, and keys
    /// in-place updates of a progress notice (`showOrUpdate`). nil → never deduped.
    public let dedupKey: String?

    public init(title: String, message: String? = nil, systemImage: String, style: Style = .info,
                isProgress: Bool = false,
                actionLabel: String? = nil, action: (@MainActor () -> Void)? = nil,
                duration: Duration? = .seconds(4), dedupKey: String? = nil) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.style = style
        self.isProgress = isProgress
        self.actionLabel = actionLabel
        self.action = action
        self.duration = duration
        self.dedupKey = dedupKey
    }

    // Identity-only equality (a stored closure isn't Equatable, and a fresh id per toast is
    // exactly the re-trigger key the overlay animates off).
    public static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// The app-wide toast queue — one shared instance (`.shared`) both shells drive. Shows one
/// toast at a time; a burst queues in order rather than clobbering. Auto-dismiss suspends
/// while the user is interacting (a drag) and resumes on release.
@MainActor
@Observable
public final class ToastCenter {
    public static let shared = ToastCenter()

    /// The toast currently on screen (nil when none). The overlay observes this.
    public private(set) var current: Toast?

    private var queue: [Toast] = []
    private var dismissTask: Task<Void, Never>?
    /// Cap the backlog so a runaway producer can't build an unbounded queue.
    private let maxQueue = 4
    /// The dwell after an interaction ends before auto-dismiss resumes.
    private let resumeDwell: Duration = .seconds(2)

    /// A fresh instance for tests; production goes through `.shared`.
    public init() {}

    /// Raise a toast. Shows it now if the stage is clear, else queues it behind the current
    /// one. A toast whose `dedupKey` matches the current or a queued one is dropped.
    public func show(_ toast: Toast) {
        if let key = toast.dedupKey,
           current?.dedupKey == key || queue.contains(where: { $0.dedupKey == key }) {
            return
        }
        guard current != nil else {
            present(toast)
            return
        }
        if queue.count >= maxQueue { queue.removeFirst() }
        queue.append(toast)
    }

    /// Raise a toast, replacing the showing one in place when their `dedupKey`s match — the
    /// update path for a progress notice ("Downloading… 40%" → "…41%") without re-animating.
    public func showOrUpdate(_ toast: Toast) {
        if let key = toast.dedupKey, current?.dedupKey == key {
            current = toast
            scheduleAutoDismiss(after: toast.duration, id: toast.id)
            return
        }
        show(toast)
    }

    /// Dismiss the showing toast (or the one matching `id`, ignoring a stale request), then
    /// advance the queue after a short gap so the out/in transitions read as distinct.
    public func dismiss(id: UUID? = nil) {
        if let id, current?.id != id { return }
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, self.current == nil else { return }
            self.present(next)
        }
    }

    /// Dismiss whatever notice carries `dedupKey` — showing or still queued. The resolve
    /// path for sticky progress notices.
    public func dismiss(dedupKey: String) {
        queue.removeAll { $0.dedupKey == dedupKey }
        if current?.dedupKey == dedupKey { dismiss() }
    }

    /// Run a toast's action (dismissing it first). No-op for an informational toast.
    public func runAction(for toast: Toast) {
        dismiss(id: toast.id)
        toast.action?()
    }

    /// Pause auto-dismiss while the user is interacting with `id`.
    public func suspendAutoDismiss(for id: UUID) {
        guard current?.id == id else { return }
        dismissTask?.cancel()
        dismissTask = nil
    }

    /// Resume auto-dismiss for `id` after the interaction ends (short dwell, not the full duration).
    public func resumeAutoDismiss(for id: UUID) {
        guard current?.id == id else { return }
        scheduleAutoDismiss(after: resumeDwell, id: id)
    }

    private func present(_ toast: Toast) {
        current = toast
        HapticFeedback.notice(toast.style)
        scheduleAutoDismiss(after: toast.duration, id: toast.id)
    }

    private func scheduleAutoDismiss(after duration: Duration?, id: UUID) {
        dismissTask?.cancel()
        dismissTask = nil
        guard let duration else { return }   // sticky — resolved by dismiss(dedupKey:)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }
}

#if os(iOS)
import UIKit
#endif

/// Style-matched haptic on toast arrival (iOS only; silent elsewhere).
enum HapticFeedback {
    @MainActor
    static func notice(_ style: Toast.Style) {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        switch style {
        case .success: generator.notificationOccurred(.success)
        case .warning: generator.notificationOccurred(.warning)
        case .error: generator.notificationOccurred(.error)
        case .info: break
        }
        #endif
    }
}
