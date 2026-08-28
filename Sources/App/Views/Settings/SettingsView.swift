import FCTAccount
import SwiftUI

/// App settings — the account and sync state, the speech model (fixed at large-v3-turbo), the
/// diarizer backend, transcript behavior, capture permissions, and model storage.
/// Presented as a sheet on both platforms (the shell's top-right control).
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    // Optional so previews/tests that host this view without the app-root injection still resolve.
    @Environment(AccountController.self) private var account: AccountController?
    @Environment(TranscriptionSync.self) private var sync: TranscriptionSync?

    init() {}

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            if let account, let sync {
                AccountSection(account: account, sync: sync)
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
                LabeledContent("Speech processing", value: "On this device")
                LabeledContent("Library storage", value: "Your FCT account")
                LabeledContent("Version", value: "0.1.0")
            } footer: {
                // Two different facts, said separately, because collapsing them is how a privacy
                // claim goes wrong: WHERE audio is processed is not WHERE it is stored.
                Text("Speech recognition, speaker identification and synthesis run entirely on this device — your audio is never sent anywhere to be transcribed. Your library is stored in your private FCT account so it reaches your other devices: the transcripts, the highlights, the speakers, any place you tagged, and the recordings themselves. Summaries and transcript questions use Apple Intelligence, which runs on this device and may use Apple's Private Cloud Compute for a long transcript.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
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
