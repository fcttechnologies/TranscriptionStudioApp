import FCTDictation
import SwiftUI

/// The dictation surface: a Done button while you speak, and the text afterwards.
///
/// It is deliberately the smallest screen in the app. A dictation's whole value is that it ends
/// somewhere else — on the clipboard, in whatever the person was writing — so this shows what was
/// heard, says the text has been copied, and gets out of the way.
struct DictationSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch app.dictation.phase {
                case .idle:
                    DictationMessage(symbol: "mic", title: "Ready", detail: nil)
                case .preparing(_, let fraction):
                    DictationProgress(title: "Preparing the speech model…", fraction: fraction)
                case .recording:
                    DictationListening()
                case .finishing:
                    DictationProgress(title: "Cleaning up your words…", fraction: nil)
                case .finished:
                    DictationResultView(result: app.dictation.result)
                case .failed(let detail):
                    DictationMessage(symbol: "exclamationmark.triangle", title: "Dictation failed", detail: detail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignMetrics.spacingL)
            .navigationTitle("Dictate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(app.dictation.isRecording ? "Cancel" : "Close") {
                        if app.dictation.isRecording { app.dictation.cancel() }
                        dismiss()
                    }
                }
                if app.dictation.isRecording {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { app.dictation.markDone() }
                            .accessibilityIdentifier(A11yID.dictationDone)
                    }
                }
            }
        }
        .onDisappear { app.dictation.reset() }
    }
}

/// The moment the person is speaking. It shows one thing — that it is listening — because
/// anything else here is something to read instead of talk.
private struct DictationListening: View {
    var body: some View {
        VStack(spacing: DesignMetrics.spacingM) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative)
            Text("Listening — tap Done when you've finished.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct DictationProgress: View {
    let title: LocalizedStringKey
    let fraction: Double?

    var body: some View {
        VStack(spacing: DesignMetrics.spacingM) {
            if let fraction {
                ProgressView(value: fraction)
                    .frame(maxWidth: 260)
            } else {
                ProgressView()
            }
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DictationMessage: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: String?

    var body: some View {
        VStack(spacing: DesignMetrics.spacingS) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// The finished text, and the two facts about it worth stating: it is already on the clipboard,
/// and — when a model did not run — nothing rewrote it.
private struct DictationResultView: View {
    let result: DictationResult?

    var body: some View {
        if let result {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
                    Text(result.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(A11yID.dictationText)

                    Label("Copied to the clipboard", systemImage: "doc.on.clipboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if result.cleanupOutcome != .cleaned {
                        Text("This device couldn't run the cleanup model, so these are your words exactly as they were heard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !result.substitutions.isEmpty {
                        VStack(alignment: .leading, spacing: DesignMetrics.spacingXS) {
                            Text("Names corrected")
                                .font(.caption.weight(.semibold))
                            ForEach(result.substitutions, id: \.self) { substitution in
                                Text(verbatim: "\(substitution.heard) → \(substitution.corrected)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } else {
            DictationMessage(symbol: "text.quote", title: "Nothing was heard", detail: nil)
        }
    }
}
