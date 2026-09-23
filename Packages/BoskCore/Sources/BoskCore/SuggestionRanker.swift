import Foundation

/// The rows of the command bar for what the user typed.
public enum SuggestionRanker {
    public struct OpenTab: Sendable {
        public var id: UUID
        public var url: URL?
        public var title: String

        public init(id: UUID, url: URL?, title: String) {
            self.id = id
            self.url = url
            self.title = title
        }
    }

    public struct HistoryItem: Sendable {
        public var url: URL
        public var title: String
        public var visitCount: Int
        public var lastVisit: Date

        public init(url: URL, title: String, visitCount: Int, lastVisit: Date) {
            self.url = url
            self.title = title
            self.visitCount = visitCount
            self.lastVisit = lastVisit
        }
    }

    public enum Suggestion: Equatable, Sendable {
        /// Go to the address the user typed, or search for it.
        case typed(URL)
        case openTab(id: UUID, title: String, url: URL?)
        case history(title: String, url: URL)
    }

    /// Row order:
    /// 1. A visited site whose host starts with the text ("gith" → github.com), so Return
    ///    goes where the user usually goes.
    /// 2. The typed address or search.
    /// 3. Open tabs that match (switch to them instead of opening a second copy).
    /// 4. Other history, most visited and most recent first.
    public static func suggestions(for rawQuery: String, openTabs: [OpenTab], history: [HistoryItem],
                                   now: Date, searchURL: URL, limit: Int = 8) -> [Suggestion] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let typed = InputClassifier.url(for: query, searchURL: searchURL) else { return [] }
        let words = query.lowercased().split(separator: " ").map(String.init)

        var rows: [Suggestion] = []
        var usedURLs: Set<String> = []

        let ranked = history
            .filter { matches(words, title: $0.title, url: $0.url) }
            .sorted { score($0, now: now) > score($1, now: now) }

        let isSingleWord = words.count == 1
        if isSingleWord, let completion = ranked.first(where: { hostStarts($0.url, with: words[0]) }) {
            // If that site is already open, switch to it.
            if let tab = openTabs.first(where: { $0.url.map(key) == key(completion.url) }) {
                rows.append(.openTab(id: tab.id, title: tab.title, url: tab.url))
            } else {
                rows.append(.history(title: completion.title, url: completion.url))
            }
            usedURLs.insert(key(completion.url))
        }
        if !usedURLs.contains(key(typed)) { rows.append(.typed(typed)) }

        for tab in openTabs where matches(words, title: tab.title, url: tab.url) {
            if let url = tab.url, usedURLs.contains(key(url)) { continue }
            rows.append(.openTab(id: tab.id, title: tab.title, url: tab.url))
            if let url = tab.url { usedURLs.insert(key(url)) }
        }
        for item in ranked where !usedURLs.contains(key(item.url)) {
            rows.append(.history(title: item.title, url: item.url))
            usedURLs.insert(key(item.url))
        }
        return Array(rows.prefix(limit))
    }

    /// Every word must appear in the title or the address.
    static func matches(_ words: [String], title: String, url: URL?) -> Bool {
        let text = (title + " " + (url?.absoluteString ?? "")).lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    static func hostStarts(_ url: URL, with prefix: String) -> Bool {
        guard var host = url.host()?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.hasPrefix(prefix)
    }

    /// Visits count more when they are recent: a site visited 10 times last year loses to
    /// a site visited 3 times this week.
    static func score(_ item: HistoryItem, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(item.lastVisit) / 86_400)
        return Double(item.visitCount) / (1 + days / 7)
    }

    /// Same page for de-duplication: ignores the scheme and a trailing slash.
    static func key(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
