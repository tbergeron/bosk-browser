import Foundation

/// A site's origin as one string, such as "https://example.com": the key of a saved
/// notification answer. WebKit gives the origin of a request as parts with port 0 for the
/// default port, and the site panel has the tab's URL, with port nil or written out.
/// All of these must make the same key, or the panel and WebKit see different answers.
public enum SiteOrigin {
    public static func key(scheme: String, host: String, port: Int?) -> String {
        let scheme = scheme.lowercased()
        let defaultPort = ["http": 80, "https": 443][scheme]
        let base = "\(scheme)://\(host.lowercased())"
        guard let port, port != 0, port != defaultPort else { return base }
        return "\(base):\(port)"
    }
}
