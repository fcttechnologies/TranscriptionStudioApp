import Foundation

extension AppModel {
    /// Handle the Share extension's wake-up ping (`transcriptionstudio://ingest…`). Returns
    /// `true` when the URL was ours (and the drop-box was drained), so callers can tell an
    /// ingest trigger from any other opened URL.
    @discardableResult
    func handleIngestURL(_ url: URL) -> Bool {
        guard IngestURLScheme.parseIngest(url) != nil else { return false }
        ingestPendingShares()
        return true
    }

    /// Drain the App Group drop-box: enqueue every item a Share extension staged as a real
    /// transcription job, then remove it from the box. Idempotent and safe to call on every
    /// foreground — an empty box is a no-op — which is the safety net for when the extension
    /// couldn't open the host directly (iOS Share extensions can't reliably open their host).
    ///
    /// A `.file` item's staged bytes are copied out to an app-owned temp file *before* the
    /// drop-box entry is removed, so the async job reads a file it owns and the shared
    /// container is left clean immediately (web-app temp parity — the OS reclaims the temp dir).
    func ingestPendingShares() {
        for item in IngestDropBox.drain() {
            switch item.kind {
            case .url:
                if let urlString = item.urlString {
                    // Mac transcribes locally; iOS queues a pendingRemote job for the Mac.
                    submitLink(urlString: urlString, title: item.title)
                }
            case .file:
                if let staged = IngestDropBox.stagedFileURL(for: item),
                   let owned = copyToOwnedTemp(staged) {
                    startTranscription(title: item.title, source: .file(owned))
                }
            }
            IngestDropBox.remove(item)
        }
    }

    /// Copy a staged file out of the shared container into this app's temp dir so the job owns
    /// its bytes independently of the drop-box (which is removed right after). Returns `nil` on
    /// failure — the entry is still removed, so a bad file can't wedge the queue.
    private func copyToOwnedTemp(_ source: URL) -> URL? {
        let ext = source.pathExtension.isEmpty ? "dat" : source.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
