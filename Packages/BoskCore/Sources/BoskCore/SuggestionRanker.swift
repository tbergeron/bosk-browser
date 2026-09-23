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

    /// A menu bar item, for the Search Commands list.
    public struct MenuCommand: Sendable {
        public var title: String
        /// The menu that has the item: "File", "View".
        public var menu: String
        /// "⇧⌘T", or empty if the item has no shortcut.
        public var shortcut: String
        public var isEnabled: Bool

        public init(title: String, menu: String, shortcut: String, isEnabled: Bool) {
            self.title = title
            self.menu = menu
            self.shortcut = shortcut
            self.isEnabled = isEnabled
        }
    }

    public enum Suggestion: Equatable, Sendable {
        /// Go to the address the user typed, or search for it.
        case typed(URL)
        case openTab(id: UUID, title: String, url: URL?)
        case history(title: String, url: URL)
        case bookmark(id: UUID, title: String, url: URL)
        /// A row of the History list: a page and the time of its last visit.
        case visit(title: String, url: URL, lastVisit: Date)
        /// A menu bar item. `index` is its position in the list the command bar got.
        case command(index: Int, title: String, menu: String, shortcut: String, isEnabled: Bool)
    }

    /// Row order:
    /// 1. A visited site whose host starts with the text ("gith" → github.com), so Return
    ///    goes where the user usually goes.
    /// 2. The typed address or search.
    /// 3. Open tabs that match (switch to them instead of opening a second copy).
    /// 4. Bookmarks that match: the user saved them on purpose.
    /// 5. Other history, most visited and most recent first.
    public static func suggestions(for rawQuery: String, openTabs: [OpenTab], history: [HistoryItem],
                                   bookmarks: [Bookmark] = [],
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
        for bookmark in bookmarks where matches(words, title: bookmark.title, url: bookmark.url) {
            guard !usedURLs.contains(key(bookmark.url)) else { continue }
            rows.append(.bookmark(id: bookmark.id, title: bookmark.title, url: bookmark.url))
            usedURLs.insert(key(bookmark.url))
        }
        for item in ranked where !usedURLs.contains(key(item.url)) {
            rows.append(.history(title: item.title, url: item.url))
            usedURLs.insert(key(item.url))
        }
        return Array(rows.prefix(limit))
    }

    // MARK: Lists (Search Tabs, History, Bookmarks)
    // Every word of the text must match. Empty text lists every row, so the user can browse.

    /// Open tabs, in tab order.
    public static func tabRows(for query: String, openTabs: [OpenTab]) -> [Suggestion] {
        let words = listWords(query)
        return openTabs.filter { matches(words, title: $0.title, url: $0.url) }
            .map { .openTab(id: $0.id, title: $0.title, url: $0.url) }
    }

    /// Visited pages, newest first. Not in score order: this is a record of where the user was.
    public static func historyRows(for query: String, history: [HistoryItem]) -> [Suggestion] {
        let words = listWords(query)
        return history.filter { matches(words, title: $0.title, url: $0.url) }
            .sorted { $0.lastVisit > $1.lastVisit }
            .map { .visit(title: $0.title, url: $0.url, lastVisit: $0.lastVisit) }
    }

    /// Bookmarks, in the order the user added them.
    public static func bookmarkRows(for query: String, bookmarks: [Bookmark]) -> [Suggestion] {
        let words = listWords(query)
        return bookmarks.filter { matches(words, title: $0.title, url: $0.url) }
            .map { .bookmark(id: $0.id, title: $0.title, url: $0.url) }
    }

    /// Menu bar items, in menu order. The words match the title only, not the menu name:
    /// "history" finds Show All History, not every item in the History menu.
    /// Items that are off stay in the list.
    public static func commandRows(for query: String, commands: [MenuCommand]) -> [Suggestion] {
        let words = listWords(query)
        return commands.enumerated()
            .filter { matches(words, title: $0.element.title, url: nil) }
            .map { .command(index: $0.offset, title: $0.element.title, menu: $0.element.menu,
                            shortcut: $0.element.shortcut, isEnabled: $0.element.isEnabled) }
    }

    /// A shortcut as the menu bar shows it: "⇧⌘T", "⌃⇥". An uppercase letter means Shift.
    public static func shortcutText(key: String, control: Bool, option: Bool, shift: Bool, command: Bool) -> String {
        guard !key.isEmpty else { return "" }
        let shift = shift || (key != key.lowercased())
        let keyText = switch key {
        case "\t": "⇥"
        case "\r": "↩"
        default: key.uppercased()
        }
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + keyText
    }

    /// The header above a day of history: "Today", "Yesterday", or "Monday, Sep 21".
    /// It uses calendar days, so a visit at 23:50 yesterday is "Yesterday" at 08:00 today.
    public static func dayTitle(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private static func listWords(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
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
