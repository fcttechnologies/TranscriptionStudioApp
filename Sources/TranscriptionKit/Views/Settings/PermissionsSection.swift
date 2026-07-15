import SwiftUI

/// The Permissions section of Settings — the one home for capture-permission state. The mic
/// row covers both platforms; the Screen Recording ladder (grant → relaunch → System
/// Settings) is macOS meeting capture's real TCC flow. Recording itself just prompts or
/// points here when a grant is missing.
struct PermissionsSection: View {
    @Environment(\.openURL) private var openURL
    @State private var micStatus: MicrophonePermission.Status = .authorized
    #if os(macOS)
    @State private var screenStatus: ScreenCapturePermission.Status = .granted
    #endif

    var body: some View {
        Section {
            micRow
            #if os(macOS)
            screenRow
            #endif
        } header: {
            Text("Permissions")
        } footer: {
            #if os(macOS)
            Text("Room recording uses the microphone. Meeting capture records system audio through ScreenCaptureKit, which macOS gates behind Screen Recording. Everything stays on this device.")
            #else
            Text("Recording uses the microphone. Everything stays on this device.")
            #endif
        }
        .onAppear(perform: refresh)
    }

    // MARK: Microphone (both platforms)

    @ViewBuilder
    private var micRow: some View {
        LabeledContent {
            Text(micStatusText)
                .foregroundStyle(micStatus == .denied ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        } label: {
            Label("Microphone", systemImage: micStatus == .denied ? "mic.slash" : "mic")
        }
        .accessibilityIdentifier("settings.permission.microphone")
        if micStatus == .denied {
            Button("Enable in System Settings…") { openURL(MicrophonePermission.settingsURL) }
        }
    }

    private var micStatusText: String {
        switch micStatus {
        case .authorized: "Allowed"
        case .notDetermined: "Asks on first recording"
        case .denied: "Off"
        }
    }

    // MARK: Screen Recording (macOS meeting capture)

    #if os(macOS)
    @ViewBuilder
    private var screenRow: some View {
        LabeledContent {
            Text(screenStatusText)
                .foregroundStyle(screenStatus == .granted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        } label: {
            Label("Screen Recording", systemImage: "rectangle.dashed.badge.record")
        }
        .accessibilityIdentifier("settings.permission.screenRecording")
        switch screenStatus {
        case .granted:
            EmptyView()
        case .notDetermined:
            Button("Grant Screen Recording…") {
                screenStatus = ScreenCapturePermission.request()
            }
        case .needsRestart:
            Text("Granted — quit and reopen Transcription Studio before starting a meeting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .denied:
            Button("Enable in System Settings…") { openURL(ScreenCapturePermission.settingsURL) }
        }
    }

    private var screenStatusText: String {
        switch screenStatus {
        case .granted: "Allowed"
        case .notDetermined: "Not granted"
        case .needsRestart: "Relaunch needed"
        case .denied: "Off"
        }
    }
    #endif

    private func refresh() {
        micStatus = MicrophonePermission.preflight()
        #if os(macOS)
        if screenStatus != .needsRestart {   // a fresh grant stays "relaunch needed" until relaunch
            screenStatus = ScreenCapturePermission.preflight()
        }
        #endif
    }
}
