import SwiftUI

/// On-device intelligence for a saved session: an Apple-Intelligence summary generated on
/// appear, and a question box for grounded Q&A over the transcript. Everything runs locally;
/// when Apple Intelligence isn't available the sheet says so and stays out of the way.
struct SessionIntelligenceSheet: View {
    let session: TranscriptSession

    @Environment(\.dismiss) private var dismiss

    private let intelligence = SessionIntelligence()

    @State private var status: IntelligenceStatus = .available
    @State private var summary: Phase = .idle
    @State private var question = ""
    @State private var answer: Phase = .idle
    @State private var answering = false

    /// A generation slot's state.
    enum Phase {
        case idle, loading, text(String), failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                if case .unavailable(let reason) = status {
                    unavailable(reason)
                } else {
                    content
                }
            }
            .navigationTitle("Intelligence")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                SheetCloseToolbar { dismiss() }
            }
        }
        #if os(macOS)
        .frame(width: DesignMetrics.macSheetSize.width,
               height: DesignMetrics.macSheetSize.height)
        #endif
        .onAppear {
            status = intelligence.status
            if status.isAvailable, case .idle = summary { generateSummary() }
        }
    }

    // MARK: Available

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignMetrics.spacingXL) {
                summarySection
                Divider()
                askSection
            }
            .padding(DesignMetrics.spacingL)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingS) {
            HStack {
                Label("Summary", systemImage: "sparkles").font(.headline)
                Spacer()
                if case .text = summary {
                    Button("Regenerate", systemImage: "arrow.clockwise") { generateSummary() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            switch summary {
            case .idle, .loading:
                HStack(spacing: DesignMetrics.spacingS) {
                    ProgressView()
                    Text("Summarizing on-device…").foregroundStyle(.secondary)
                }
                .padding(.vertical, DesignMetrics.spacingS)
            case .text(let value):
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .failed(let message):
                noticeRow(message)
            }
        }
    }

    private var askSection: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingS) {
            Label("Ask this transcript", systemImage: "questionmark.bubble").font(.headline)
            Text("Answers come only from what was said in this recording.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: DesignMetrics.spacingS) {
                TextField("e.g. What did we decide about the budget?", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(askQuestion)
                    .accessibilityIdentifier("intelligence.question")
                Button("Ask", systemImage: "arrow.up.circle.fill") { askQuestion() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || answering)
            }
            switch answer {
            case .idle:
                EmptyView()
            case .loading:
                HStack(spacing: DesignMetrics.spacingS) {
                    ProgressView()
                    Text("Thinking…").foregroundStyle(.secondary)
                }
                .padding(.vertical, DesignMetrics.spacingS)
            case .text(let value):
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignMetrics.spacingM)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: DesignMetrics.cornerM))
            case .failed(let message):
                noticeRow(message)
            }
        }
    }

    private func noticeRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Unavailable

    private func unavailable(_ reason: IntelligenceUnavailable) -> some View {
        ContentUnavailableView {
            Label("Apple Intelligence unavailable", systemImage: "sparkles.slash")
        } description: {
            Text(reason.message)
        }
    }

    // MARK: Actions

    private func generateSummary() {
        summary = .loading
        let text = session.fullText
        Task {
            do {
                let result = try await intelligence.summarize(transcript: text)
                summary = .text(result)
            } catch {
                summary = .failed(SessionIntelligence.errorMessage(for: error))
            }
        }
    }

    private func askQuestion() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !answering else { return }
        answering = true
        answer = .loading
        let text = session.fullText
        Task {
            defer { answering = false }
            do {
                let result = try await intelligence.answer(question: q, transcript: text)
                answer = .text(result)
            } catch {
                answer = .failed(SessionIntelligence.errorMessage(for: error))
            }
        }
    }
}
