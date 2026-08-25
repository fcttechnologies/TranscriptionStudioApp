import Foundation

/// Path + URL math for pre-downloading a WhisperKit model through Background Assets. Every
/// method takes the roots it needs (no ambient `FileManager` container lookups), so the whole
/// type is pure and unit-tests without a real App Group or Application Support container.
///
/// It bridges three layouts:
/// - **HuggingFace source** — `https://huggingface.co/<repo>/resolve/main/<variant>/<relpath>`,
///   where WhisperKit's model files actually live.
/// - **App Group staging** — `<appGroup>/BackgroundAssets/WhisperKit/models/<repo>/<variant>/<relpath>`,
///   where the extension parks finished files (the only place both the sandboxed extension and
///   the app can write; the app's own Application Support is not shared with the extension).
/// - **WhisperKit download base** — `<downloadBase>/models/<repo>/<variant>/<relpath>`, the exact
///   tree `WhisperKit.download` lays down and `WhisperKitAsrEngine.defaultDownloadBase` points at.
///   Placing files here makes WhisperKit find the model and skip its own download.
///
/// The staging root and the download base share the same `models/…` sub-layout, so the app's
/// launch-time relocation is a straight per-file move.
enum WhisperKitModelLayout {
    static let huggingFaceHost = "huggingface.co"

    /// The remote HuggingFace URL for a single asset.
    static func downloadURL(repo: String, variant: String, relativePath: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = huggingFaceHost
        components.path = "/\(repo)/resolve/main/\(variant)/\(relativePath)"
        return components.url
    }

    /// An asset's path relative to a WhisperKit download base: `models/<repo>/<variant>/<relpath>`.
    /// This doubles as the download's stable `identifier`, so the extension's finish callback
    /// recovers the exact destination straight from `BADownload.identifier` — no side table.
    static func installRelativePath(repo: String, variant: String, relativePath: String) -> String {
        "models/\(repo)/\(variant)/\(relativePath)"
    }

    /// The root under the App Group container where the extension stages finished files.
    static func stagingRoot(appGroupContainer: URL) -> URL {
        appGroupContainer.appendingPathComponent("BackgroundAssets/WhisperKit", isDirectory: true)
    }

    /// Where one finished asset is staged inside the App Group container.
    static func stagedURL(appGroupContainer: URL, installRelativePath: String) -> URL {
        stagingRoot(appGroupContainer: appGroupContainer).appendingPathComponent(installRelativePath)
    }

    /// The final on-disk location of one asset under the WhisperKit download base.
    static func installedURL(downloadBase: URL, installRelativePath: String) -> URL {
        downloadBase.appendingPathComponent(installRelativePath)
    }

    /// The assets from `manifest` that still need downloading, given what's already present.
    /// An asset is considered present when a file exists at the given location with exactly the
    /// manifest's size. `sizeAt` returns the byte size of a file at a URL (or `nil` if absent) —
    /// injected so this stays pure and testable. Checks the download base first (already
    /// installed), then the staging area (downloaded but not yet relocated).
    static func pendingAssets(
        manifest: WhisperKitModelManifest,
        downloadBase: URL,
        appGroupContainer: URL,
        sizeAt: (URL) -> Int?
    ) -> [WhisperKitModelAsset] {
        manifest.assets.filter { asset in
            let installPath = installRelativePath(repo: manifest.repo, variant: manifest.variant, relativePath: asset.path)
            let installed = installedURL(downloadBase: downloadBase, installRelativePath: installPath)
            if sizeAt(installed) == asset.size { return false }
            let staged = stagedURL(appGroupContainer: appGroupContainer, installRelativePath: installPath)
            if sizeAt(staged) == asset.size { return false }
            return true
        }
    }
}
