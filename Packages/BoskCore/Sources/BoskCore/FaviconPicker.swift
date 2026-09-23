import Foundation

/// Picks the best icon a page declares, for a 32 pt tile on a 2x screen (64 px).
public enum FaviconPicker {
    public struct Candidate: Equatable, Sendable {
        public var url: URL
        /// The `sizes` attribute, for example "32x32", "16x16 32x32" or "any".
        public var sizes: String
        public var rel: String

        public init(url: URL, sizes: String, rel: String) {
            self.url = url
            self.sizes = sizes
            self.rel = rel
        }
    }

    static let targetPixels = 64

    /// - Returns: The best declared icon, or `/favicon.ico` at the page's origin when
    ///   the page declares none. Nil only when the page URL has no host.
    public static func pick(from candidates: [Candidate], pageURL: URL) -> URL? {
        // Only web icons: a page must not make Bosk read file:// or other local URLs.
        let usable = candidates.filter {
            ["http", "https"].contains($0.url.scheme?.lowercased()) && !$0.url.pathExtension.lowercased().hasPrefix("svg")
        }
        if let best = usable.max(by: { score($0) < score($1) }) { return best.url }
        guard let host = pageURL.host(), let scheme = pageURL.scheme else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = pageURL.port
        components.path = "/favicon.ico"
        return components.url
    }

    /// Icons at or just above 64 px score best: they stay sharp and are small to download.
    /// Smaller icons score lower the smaller they are; much bigger icons lose a little.
    static func score(_ candidate: Candidate) -> Int {
        var size = largestSize(candidate.sizes)
        if size == nil, candidate.rel.contains("apple-touch-icon") { size = 180 }
        guard let size else { return 1 } // Unknown size: better than nothing.
        if size >= targetPixels { return 10_000 - (size - targetPixels) }
        return size * 10
    }

    /// The page writes `sizes`, so values outside 1...4096 are ignored. Without this limit,
    /// a negative size overflows in `score` and stops the app.
    static func largestSize(_ sizes: String) -> Int? {
        sizes.lowercased().split(separator: " ")
            .compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }
            .filter { (1...4096).contains($0) }
            .max()
    }
}
