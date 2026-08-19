import FCTAccount
import SwiftUI

/// App settings — the account and sync state, the speech model (fixed at large-v3-turbo), the
/// diarizer backend, transcript behavior, capture permissions, and model storage.
/// Presented as a sheet on both platforms (the shell's top-right control).
public struct SettingsView: View {
    @Environment(AppModel.self) private var app
    // Optional so previews/tests that host this view without the app-root injection still resolve.
    @Environment(AccountController.self) private var account: AccountController?
    @Environment(TranscriptionSync.self) private var sync: TranscriptionSync?

    @State private var signInPresented = false

    public init() {}

    public var body: some View {
        @Bindable var settings = app.settings
        Form {
            if let account, let sync {
                AccountSection(account: account, sync: sync, signInPresented: $signInPresented)
            }
            Section {
                LabeledContent("Speech model", value: settings.whisperModel.displayName)
                Toggle("Capture word-level timestamps", isOn: $settings.wordTimestamps)
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("On-device Whisper large-v3-turbo — the speed/accuracy sweet spot.")
            }
            Section("Diarization") {
                Picker("Backend", selection: $settings.diarizerBackend) {
                    ForEach(diarizerBackendOptions) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                Text(settings.diarizerBackend.detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Transcript") {
                Toggle("Auto-follow the live transcript", isOn: $settings.autoFollowTranscript)
            }
            PermissionsSection(locationCaptureEnabled: $settings.locationCaptureEnabled)
            StorageSection()
            Section {
                LabeledContent("On-device", value: "All processing stays local")
                LabeledContent("Version", value: "0.1.0")
            } footer: {
                Text("Transcription and synthesis run entirely on this device — no audio is ever sent anywhere to be processed. With an account, your library is also stored in your private FCT account so it reaches your other devices.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .modifier(SignInSheet(isPresented: $signInPresented, account: account))
    }

    /// iOS can never provision the Sortformer model — `DiarizationBackend.makeEngine`'s guard
    /// always falls back to SpeakerKit there (no locally re-exported model) — so the picker
    /// only offers backends that actually run on this platform, instead of listing a choice
    /// that silently becomes something else.
    private var diarizerBackendOptions: [AppSettings.DiarizerBackend] {
        #if os(iOS)
        AppSettings.DiarizerBackend.allCases.filter { $0 != .sortformer }
        #else
        AppSettings.DiarizerBackend.allCases
        #endif
    }
}


/// The sign-in sheet, applied only where the app root injected an account controller — previews
/// and tests host `SettingsView` without one.
private struct SignInSheet: ViewModifier {
    @Binding var isPresented: Bool
    let account: AccountController?

    func body(content: Content) -> some View {
        if let account {
            content.transcriptionSignInSheet(isPresented: $isPresented, account: account)
        } else {
            content
        }
    }
}
