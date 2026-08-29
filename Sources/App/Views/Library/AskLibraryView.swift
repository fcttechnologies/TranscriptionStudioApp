import SwiftUI

/// **Flagship A's in-app surface**: ask a question across your whole transcript library and get an
/// on-device answer, retrieved from the sessions that match (the same semantic RAG the Siri intent
/// uses, via `TranscriptLibraryAssistant`). Everything runs locally; when Apple Intelligence isn't
/// available the view says so and stays out of the way — matching `SessionIntelligenceSheet`'s
/// degrade-gracefully posture and visual language.
struct AskLibraryView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var available = TranscriptLibraryAssistant.isAvailable
    @State private var question = ""
    @State private var answer: Phase = .idle
    @State private var asking = false

    /// The answer slot's state.
    enum Phase {
        case idle, loading, text(String), failed(String)
    }

    private let examples = [
        "What did we decide at the last meeting?",
        "What action items came out of this week?",
        "Where did I say I'd meet Sergio?",
    ]

    var body: some View {
        NavigationStack {
            Group {
                if available {
                    content
                } else {
                    unavailable
                }
            }
            .navigationTitle("Ask your library")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                SheetCloseToolbar { dismiss() }
            }
        }
        #if os(macOS)
        .frame(width: DesignMetrics.macSheetSize.width, height: DesignMetrics.macSheetSize.height)
        #endif
        .onAppear { available = TranscriptLibraryAssistant.isAvailable }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignMetrics.spacingXL) {
                askSection
                if case .idle = answer { examplesSection }
            }
            .padding(DesignMetrics.spacingL)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    private var askSection: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingS) {
            Label("Ask across every transcript", systemImage: "sparkles.rectangle.stack").font(.headline)
            Text("Answers come only from your own saved transcripts, on-device.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: DesignMetrics.spacingS) {
                TextField("e.g. What did we decide about the budget?", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                    .accessibilityIdentifier(A11yID.askLibraryQuestion)
                Button("Ask", systemImage: "arrow.up.circle.fill") { ask() }
                    .accessibilityIdentifier(A11yID.askLibrarySubmit)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
            }
            switch answer {
            case .idle:
                EmptyView()
            case .loading:
                HStack(spacing: DesignMetrics.spacingS) {
                    ProgressView()
                    Text("Searching your library…").foregroundStyle(.secondary)
                }
                .padding(.vertical, DesignMetrics.spacingS)
            case .text(let value):
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignMetrics.spacingM)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: DesignMetrics.cornerM))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingS) {
            Text("Try asking").font(.subheadline).foregroundStyle(.secondary)
            ForEach(examples, id: \.self) { example in
                Button {
                    question = example
                    ask()
                } label: {
                    Label(example, systemImage: "text.bubble")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Apple Intelligence unavailable", systemImage: "sparkles.slash")
        } description: {
            Text(SessionIntelligence.currentStatus().message)
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !asking else { return }
        asking = true
        answer = .loading
        Task {
            defer { asking = false }
            switch await TranscriptLibraryAssistant.ask(q) {
            case .success(let value):
                answer = .text(value)
            case .failure(.unavailable):
                available = false
                answer = .failed(SessionIntelligence.currentStatus().message)
            case .failure(.failed):
                answer = .failed("Something went wrong. Please try again.")
            }
        }
    }
}
