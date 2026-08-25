// CapturePermissions — the real OS permission preflights the Record surface drives, so a run is
// never started into a dead recording. Screen Recording (meeting mode) is a macOS TCC gate with a
// restart-after-first-grant quirk; the microphone (room mode) is gated on both platforms. The
// CoreGraphics screen-capture calls are Mac-only (meeting mode is Mac-only anyway) and gated.
//
// These mirror the semantics TranscriptionMacKit's MeetingCaptureSource models as
// MeetingCaptureState; the Record surface lives in the cross-platform kit, so the status types
// live here rather than importing the Mac-only module.

import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Screen Recording permission (macOS meeting capture). Off macOS there is no gate.
enum ScreenCapturePermission {
    enum Status: Equatable, Sendable {
        case granted
        case notDetermined
        /// Just granted for the first time — macOS requires an app restart before capture works.
        case needsRestart
        case denied
    }

    /// System Settings › Privacy & Security › Screen Recording.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Current status, without prompting.
    static func preflight() -> Status {
        #if os(macOS)
        return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        #else
        return .granted   // meeting mode is Mac-only; no screen-capture gate elsewhere
        #endif
    }

    /// Request access (prompts on first use). A fresh grant needs an app restart to take effect,
    /// so a just-granted result is reported as `.needsRestart` rather than `.granted`.
    static func request() -> Status {
        #if os(macOS)
        if CGPreflightScreenCaptureAccess() { return .granted }
        return CGRequestScreenCaptureAccess() ? .needsRestart : .denied
        #else
        return .granted
        #endif
    }
}

/// Microphone permission (room mode, both platforms). Preflight-only — the capture source itself
/// requests when the status is undetermined; a denied status is surfaced as a card with a deep link.
enum MicrophonePermission {
    enum Status: Equatable, Sendable {
        case authorized
        case notDetermined
        case denied
    }

    /// Deep link to the microphone privacy pane (macOS) / this app's settings (iOS).
    static var settingsURL: URL {
        #if os(macOS)
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        #else
        return URL(string: UIApplication.openSettingsURLString)!
        #endif
    }

    /// Current status, without prompting.
    static func preflight() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}
