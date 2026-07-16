import Foundation

/// The custom URL scheme the Share extension uses to wake the host app after staging an item.
/// The URL is only a trigger — the payload lives in the App Group drop-box — so the host
/// drains the whole box on receipt; the `id` is carried for logging/directness.
public enum IngestURLScheme {
    public static let scheme = "transcriptionstudio"
    public static let ingestHost = "ingest"

    /// `transcriptionstudio://ingest?id=<uuid>` — the ping for a freshly-staged item.
    public static func ingestURL(id: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ingestHost
        components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        // The components are all valid, so `url` is non-nil; the fallback keeps this total.
        return components.url ?? URL(string: "\(scheme)://\(ingestHost)")!
    }

    /// A parsed ingest trigger — carries the staged item's `id` when present (the host drains
    /// the whole box regardless, so a missing/garbage id is harmless).
    public struct Ping: Equatable, Sendable {
        public let id: UUID?
    }

    /// A non-nil `Ping` when `url` is an ingest trigger for this app; `nil` otherwise.
    public static func parseIngest(_ url: URL) -> Ping? {
        guard url.scheme == scheme, url.host == ingestHost else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let idString = components?.queryItems?.first(where: { $0.name == "id" })?.value
        return Ping(id: idString.flatMap(UUID.init(uuidString:)))
    }
}
