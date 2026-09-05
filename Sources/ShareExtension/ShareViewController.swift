import Foundation
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
typealias ShareHostController = UIViewController
#elseif os(macOS)
import AppKit
typealias ShareHostController = NSViewController
#endif

/// The Share extension's principal view controller, shared by the macOS and iOS extension
/// targets. It does the minimum an extension should: grab the shared item, stage it into the
/// App Group drop-box (bytes for an iOS media file, a string for a macOS web URL), ping the
/// host app via the custom URL scheme, and complete. It never transcribes — the extension is
/// memory-capped (~120 MB) and a speech model would blow that; the host does the real work.
@objc(ShareViewController)
final class ShareViewController: ShareHostController {
    private enum ShareError: Error { case noItem }

    #if os(macOS)
    override func loadView() { self.view = makeStatusView() }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        #if os(iOS)
        installStatusLabel()
        #endif
        Task { await run() }
    }

    // MARK: Flow

    private func run() async {
        guard let provider = firstAttachment() else { return finish() }

        let kind = SharedItemClassifier.classify(typeIdentifiers: provider.registeredTypeIdentifiers)
        do {
            let staged: PendingIngest
            switch kind {
            case .mediaFile:
                staged = try await stageMediaFile(from: provider)
            case .webURL:
                staged = try await stageWebURL(from: provider)
            case .unsupported:
                return finish()
            }
            openHost(with: staged.id)
        } catch {
            // Nothing durable to hand off — just dismiss cleanly rather than hang the sheet.
        }
        finish()
    }

    private func firstAttachment() -> NSItemProvider? {
        (extensionContext?.inputItems.first as? NSExtensionItem)?.attachments?.first
    }

    // MARK: Stage

    /// Copy a shared movie/audio file's bytes into the drop-box. The provider's file URL is
    /// only valid inside the completion, so the copy (in `stageFile`) happens there.
    private func stageMediaFile(from provider: NSItemProvider) async throws -> PendingIngest {
        let typeIdentifier = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            ? UTType.movie.identifier
            : UTType.audio.identifier
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareError.noItem)
                    return
                }
                do {
                    let title = Self.fileTitle(url.lastPathComponent)
                    let item = try IngestDropBox.stageFile(from: url, title: title)
                    continuation.resume(returning: item)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func stageWebURL(from provider: NSItemProvider) async throws -> PendingIngest {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareError.noItem)
                    return
                }
                do {
                    let string = url.absoluteString
                    let staged = try IngestDropBox.stageURL(string, title: Self.urlTitle(string))
                    continuation.resume(returning: staged)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Open host + finish

    @MainActor
    private func openHost(with id: UUID) {
        let url = IngestURLScheme.ingestURL(id: id)
        #if os(macOS)
        extensionContext?.open(url)
        #elseif os(iOS)
        // iOS Share extensions can't call `UIApplication.shared` (extension-unavailable) or rely
        // on `NSExtensionContext.open` (unsupported for the share point), so walk the responder
        // chain to the UIApplication and open the host URL through it. The host also drains the
        // drop-box on next foreground, so this is best-effort, not the only path.
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
        #endif
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: Titles

    /// A media file's session title: its filename stem, or a generic fallback. `nonisolated`
    /// so the background item-load completions can call it without hopping to the main actor.
    nonisolated static func fileTitle(_ filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? "Shared audio" : stem
    }

    /// A shared link's title: "Link · host", falling back to the raw string.
    nonisolated static func urlTitle(_ string: String) -> String {
        URL(string: string)?.host().map { "Link · \($0)" } ?? string
    }

    // MARK: Minimal status UI

    #if os(macOS)
    private func makeStatusView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        let label = NSTextField(labelWithString: "Sending to Transcription Studio…")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
    #elseif os(iOS)
    private func installStatusLabel() {
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "Sending to Transcription Studio…"
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
    #endif
}
