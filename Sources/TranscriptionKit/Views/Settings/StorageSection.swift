import SwiftUI

/// The Storage section of Settings — what's actually downloaded on this device, how much
/// space it costs, and a way to free it up. Reads `ModelStorageScanner` (never the settings
/// picker, which only names a *preference*) so it never lies about what's really on disk, and
/// re-scans after every delete so the list and the total stay live.
struct StorageSection: View {
    @Environment(AppModel.self) private var app
    @State private var models: [StoredModel] = []
    @State private var pendingDeletion: StoredModel?
    @State private var deletionError: String?

    var body: some View {
        Section {
            if models.isEmpty {
                Text("No speech models downloaded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(models) { model in
                    StorageModelRow(model: model, isSelected: isSelected(model)) {
                        pendingDeletion = model
                    }
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            if models.isEmpty {
                Text("Speech and diarization models download automatically the first time they're used.")
            } else {
                Text("\(totalBytes.formatted(.byteCount(style: .file))) used on this device. Deleting a model frees the space — it downloads again automatically the next time it's needed.")
            }
        }
        .onAppear(perform: refresh)
        .confirmationDialog("Delete this model?", item: $pendingDeletion, titleVisibility: .visible) { model in
            Button("Delete \(model.displayName)", role: .destructive) { delete(model) }
        } message: { model in
            if isSelected(model) {
                Text("\(model.displayName) is your currently selected model. Deleting it frees \(model.bytes.formatted(.byteCount(style: .file))) and it will re-download automatically the next time it's needed.")
            } else {
                Text("Frees \(model.bytes.formatted(.byteCount(style: .file))). It will download again automatically if you use it.")
            }
        }
        .alert("Couldn't delete model", item: $deletionError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var totalBytes: Int64 {
        models.reduce(0) { $0 + $1.bytes }
    }

    private func isSelected(_ model: StoredModel) -> Bool {
        switch model.kind {
        case .whisper(let variant): variant == app.settings.whisperModel
        case .diarizer: app.settings.diarizerBackend == .sortformer
        }
    }

    private func refresh() {
        models = ModelStorageScanner.scan()
    }

    private func delete(_ model: StoredModel) {
        do {
            try ModelStorageScanner.delete(model)
            refresh()
        } catch {
            deletionError = error.localizedDescription
        }
    }
}

/// One downloaded model: name + kind, its size, and a delete affordance. A "Selected" badge
/// marks whichever model backs the currently-active engine (still deletable — see the
/// confirmation copy for what deleting the active model does).
private struct StorageModelRow: View {
    let model: StoredModel
    let isSelected: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DesignMetrics.spacingM) {
            VStack(alignment: .leading, spacing: DesignMetrics.spacingXS / 2) {
                HStack(spacing: DesignMetrics.spacingS) {
                    Text(model.displayName)
                    if isSelected {
                        Text("Selected")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, DesignMetrics.spacingS)
                            .padding(.vertical, DesignMetrics.spacingXS / 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.bytes.formatted(.byteCount(style: .file)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(model.displayName)")
        }
        .accessibilityIdentifier("settings.storage.model.\(model.id)")
    }
}
