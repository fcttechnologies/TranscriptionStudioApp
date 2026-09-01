import FCTAccount
import FCTSupport
import SwiftUI

/// App settings — the account and sync state, the speech model (fixed at large-v3-turbo), the
/// diarizer backend, transcript behavior, capture permissions, and model storage.
/// Presented as a sheet on both platforms (the shell's top-right control).
///
/// **The two platforms get different shapes from the same sections.** iOS reads one scrolling
/// Form, which is the phone idiom and the right one there. macOS reads a pane per group behind
/// tabs: the same content in one column is ~1,900pt of Form inside a fixed sheet, which is a
/// phone layout wearing a Mac window — a reader has to scroll to learn what settings even exist.
/// The group vars below are the single source both shapes compose.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    // Optional so previews/tests that host this view without the app-root injection still resolve.
    @Environment(AccountController.self) private var account: AccountController?
    @Environment(TranscriptionSync.self) private var sync: TranscriptionSync?

    #if os(macOS)
    @State private var pane: Pane = .account

    /// The macOS panes, in the order they read: who you are, what the app does with sound, what
    /// it is allowed to touch, what it costs on disk, and what it discloses plus how to reach us.
    private enum Pane: String, CaseIterable, Identifiable {
        case account, transcription, permissions, storage, about
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .account: "Account"
            case .transcription: "Transcription"
            case .permissions: "Permissions"
            case .storage: "Storage"
            case .about: "About"
            }
        }

    }
    #endif

    init() {}

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Picker("Settings section", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DesignMetrics.spacingL)
            .padding(.vertical, DesignMetrics.spacingM)
            Divider()
            Form { sections(for: pane) }
                .formStyle(.grouped)
                .softScrollEdges()
        }
        .navigationTitle("Settings")
        #else
        Form {
            accountGroup
            transcriptionGroup
            permissionsGroup
            storageGroup
            aboutGroup
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private func sections(for pane: Pane) -> some View {
        switch pane {
        case .account: accountGroup
        case .transcription: transcriptionGroup
        case .permissions: permissionsGroup
        case .storage: storageGroup
        case .about: aboutGroup
        }
    }
    #endif

    // MARK: The groups — one definition, composed by both shapes

    @ViewBuilder
    private var accountGroup: some View {
        if let account, let sync {
            AccountSection(account: account, sync: sync)
        }
    }

    @ViewBuilder
    private var transcriptionGroup: some View {
        @Bindable var settings = app.settings
        Section {
            LabeledContent("Speech model", value: settings.whisperModel.displayName)
            Toggle("Capture word-level timestamps", isOn: $settings.wordTimestamps)
                .accessibilityIdentifier(A11yID.settingsWordTimestamps)
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
                .accessibilityIdentifier(A11yID.settingsAutoFollow)
        }
    }

    @ViewBuilder
    private var permissionsGroup: some View {
        @Bindable var settings = app.settings
        PermissionsSection(locationCaptureEnabled: $settings.locationCaptureEnabled)
    }

    @ViewBuilder
    private var storageGroup: some View {
        StorageSection()
        #if DEBUG
        DebugToolsSection()
        #endif
    }

    @ViewBuilder
    private var aboutGroup: some View {
        Section {
            // `LabeledContent(_:value:)` renders its value through `Text(_: S)`, which does not
            // localize — so a privacy disclosure written that way ships English to every
            // locale. The trailing-closure form takes a `LocalizedStringKey` and does.
            LabeledContent("Speech processing") { Text("On this device") }
            LabeledContent("Library storage") { Text("Your FCT account") }
            LabeledContent("Version", value: "0.1.0")
        } footer: {
            // Two different facts, said separately, because collapsing them is how a privacy
            // claim goes wrong: WHERE audio is processed is not WHERE it is stored.
            Text("Speech recognition, speaker identification and synthesis run entirely on this device — your audio is never sent anywhere to be transcribed. Your library is stored in your private FCT account so it reaches your other devices: the transcripts, the highlights, the speakers, any place you tagged, and the recordings themselves. Summaries and transcript questions use Apple Intelligence, which runs on this device and may use Apple's Private Cloud Compute for a long transcript.")
        }
        SupportSettingsSection(appName: "Transcription Studio")
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
