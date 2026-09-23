import Foundation

/// Turns what the user types in the command bar into a URL to load:
/// either the address they typed, or a search for it.
public enum InputClassifier {
    /// Schemes that load directly when typed with "://" or "about:".
    static let directSchemes: Set<String> = ["http", "https", "file", "about"]

    /// - Parameters:
    ///   - rawInput: The text from the command bar.
    ///   - searchURL: The search page; the query goes in its `q` parameter.
    /// - Returns: nil when the input is empty.
    public static func url(for rawInput: String, searchURL: URL) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let url = explicitSchemeURL(input) { return url }

        // A space means words, not an address ("what is x.com").
        if !input.contains(where: \.isWhitespace), let url = bareAddressURL(input) {
            return url
        }
        return search(input, searchURL: searchURL)
    }

    private static func explicitSchemeURL(_ input: String) -> URL? {
        let lower = input.lowercased()
        if lower.hasPrefix("about:") { return URL(string: input) }
        guard let range = lower.range(of: "://") else { return nil }
        let scheme = String(lower[..<range.lowerBound])
        guard directSchemes.contains(scheme) else { return nil }
        return URL(string: input)
    }

    /// "x.com/path", "localhost:3000", "192.168.1.1" and "[::1]:8080" load as addresses.
    private static func bareAddressURL(_ input: String) -> URL? {
        let hostAndPort = input.prefix { !"/?#".contains($0) }
        let host: Substring
        if hostAndPort.hasPrefix("[") {
            guard let close = hostAndPort.firstIndex(of: "]") else { return nil }
            host = hostAndPort[...close]
            let rest = hostAndPort[hostAndPort.index(after: close)...]
            guard rest.isEmpty || isPort(rest) else { return nil }
        } else {
            let parts = hostAndPort.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            if parts.count == 2 { guard isPort(":" + parts[1]) else { return nil } }
            host = parts[0]
        }

        // Local machines and IP addresses usually do not have HTTPS.
        if host.lowercased() == "localhost" || isIPv4(host) || host.hasPrefix("[") {
            return URL(string: "http://" + input)
        }
        return isDomain(host) ? URL(string: "https://" + input) : nil
    }

    private static func isPort(_ text: Substring) -> Bool {
        guard text.first == ":" else { return false }
        let digits = text.dropFirst()
        return !digits.isEmpty && digits.count <= 5 && digits.allSatisfy(\.isASCIIDigit)
    }

    private static func isIPv4(_ host: Substring) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCIIDigit) && Int(part)! <= 255
        }
    }

    /// Labels of letters, digits and hyphens, and a last label of 2+ letters.
    /// There is no list of real top-level domains, so "node.js" counts as a domain.
    private static func isDomain(_ host: Substring) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2,
              tld.allSatisfy(\.isLetter) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func search(_ query: String, searchURL: URL) -> URL? {
        guard var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // URLComponents leaves "+" as is, and servers read it as a space ("c++" → "c  ").
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
