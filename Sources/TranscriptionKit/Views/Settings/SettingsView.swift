import SwiftUI

/// App settings — the speech model (fixed at large-v3-turbo), the diarizer backend, transcript
/// behavior, capture permissions, and model storage.
/// Presented as a sheet on both platforms (the shell's top-right control).
public struct SettingsView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        @Bindable var settings = app.settings
        Form {
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
            PermissionsSection()
            StorageSection()
            Section {
                LabeledContent("On-device", value: "All processing stays local")
                LabeledContent("Version", value: "0.1.0")
            } footer: {
                Text("Transcription Studio runs entirely on this device. Nothing is uploaded.")
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
