import Foundation

/// Path + URL math for the speech models' journey from the hosted repo to the engine. Every
/// method takes the roots it needs (no ambient `FileManager` container lookups), so the whole
/// type is pure and unit-tests without a real App Group or Application Support container.
///
/// Three layouts, one relative path (`<model>/<relpath>`) through all of them:
/// - **Hosted source** — `https://huggingface.co/<repo>/resolve/main/<model>/<relpath>`.
/// - **App Group staging** — `<appGroup>/BackgroundAssets/fctspeech/<model>/<relpath>`, where
///   the extension parks finished files (the only place both the sandboxed extension and the
///   app can write; the app's own Application Support is not shared with the extension).
/// - **Models root** — `<root>/<model>/<relpath>`, the tree the engines load from
///   (`SpeechModel.root()`).
///
/// The relative path doubles as a download's stable `identifier`, so the extension's finish
/// callback recovers the exact destination straight from `BADownload.identifier`; no side table.
enum ModelLayout {
    static let host = "huggingface.co"

    /// The remote URL for one asset.
    static func downloadURL(repo: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(repo)/resolve/main/\(path)"
        return components.url
    }

    /// The root under the App Group container where the extension stages finished files.
    static func stagingRoot(appGroupContainer: URL) -> URL {
        appGroupContainer.appendingPathComponent("BackgroundAssets/fctspeech", isDirectory: true)
    }

    /// Where one finished asset is staged inside the App Group container.
    static func stagedURL(appGroupContainer: URL, path: String) -> URL {
        stagingRoot(appGroupContainer: appGroupContainer).appendingPathComponent(path)
    }

    /// The final on-disk location of one asset under the models root.
    static func installedURL(root: URL, path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// The assets that still need downloading, given what's already present: an asset is present
    /// when a file exists at exactly the manifest's size, installed under `root` or staged in the
    /// App Group (downloaded but not yet relocated). `sizeAt` returns a file's byte size or `nil`,
    /// injected so this stays pure. `nil` for the App Group means there is no staging area.
    static func pendingAssets(
        _ assets: [ModelAsset],
        root: URL,
        appGroupContainer: URL?,
        sizeAt: (URL) -> Int?
    ) -> [ModelAsset] {
        assets.filter { asset in
            if sizeAt(installedURL(root: root, path: asset.path)) == asset.size { return false }
            if let appGroupContainer,
               sizeAt(stagedURL(appGroupContainer: appGroupContainer, path: asset.path)) == asset.size {
                return false
            }
            return true
        }
    }
}
