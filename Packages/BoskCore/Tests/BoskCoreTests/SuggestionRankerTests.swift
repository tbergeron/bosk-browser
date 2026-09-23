import Foundation
import Testing
@testable import BoskCore

/// The command bar is how the user goes anywhere. Return takes the first row, so the
/// first row must be where the user most likely wants to go.
struct SuggestionRankerTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let google = URL(string: "https://www.google.com/search")!

    func visit(_ url: String, _ title: String, count: Int, daysAgo: Double = 0) -> SuggestionRanker.HistoryItem {
        .init(url: URL(string: url)!, title: title, visitCount: count, lastVisit: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func rows(_ query: String, tabs: [SuggestionRanker.OpenTab] = [],
              history: [SuggestionRanker.HistoryItem] = [],
              bookmarks: [Bookmark] = []) -> [SuggestionRanker.Suggestion] {
        SuggestionRanker.suggestions(for: query, openTabs: tabs, history: history, bookmarks: bookmarks,
                                     now: now, searchURL: google)
    }

    @Test("A few letters of a visited site put that site first, so Return goes there")
    func hostCompletionFirst() {
        let result = rows("gith", history: [visit("https://github.com/", "GitHub", count: 20)])
        #expect(result.first == .history(title: "GitHub", url: URL(string: "https://github.com/")!))
        #expect(result.dropFirst().first == .typed(URL(string: "https://www.google.com/search?q=gith")!))
    }

    @Test("With no matching site, the first row searches for the text")
    func searchFirst() {
        let result = rows("weather tomorrow", history: [visit("https://github.com/", "GitHub", count: 20)])
        #expect(result == [.typed(URL(string: "https://www.google.com/search?q=weather%20tomorrow")!)])
    }

    @Test("A matching open tab is offered, so the user switches instead of opening a copy")
    func openTabOffered() {
        let id = UUID()
        let result = rows("inbox", tabs: [.init(id: id, url: URL(string: "https://mail.google.com")!, title: "Inbox (3)")])
        #expect(result.contains(.openTab(id: id, title: "Inbox (3)", url: URL(string: "https://mail.google.com")!)))
    }

    @Test("A recent site outranks a site that had more visits long ago")
    func recencyMatters() {
        let result = rows("news", history: [
            visit("https://old-news.example/", "Old news", count: 10, daysAgo: 365),
            visit("https://daily-news.example/", "Daily news", count: 3, daysAgo: 1),
        ])
        let historyTitles = result.compactMap { row -> String? in
            if case .history(let title, _) = row { return title } else { return nil }
        }
        #expect(historyTitles == ["Daily news", "Old news"])
    }

    @Test("A page is listed once, even when it is open and in history")
    func noDuplicates() {
        let url = URL(string: "https://swift.org/")!
        let result = rows("swift", tabs: [.init(id: UUID(), url: url, title: "Swift")],
                          history: [visit("https://swift.org", "Swift", count: 5)])
        let swiftRows = result.filter {
            switch $0 {
            case .openTab(_, _, let rowURL): rowURL == url
            case .history(_, let rowURL): SuggestionRanker.key(rowURL) == "swift.org"
            case .typed, .bookmark, .visit, .command: false
            }
        }
        #expect(swiftRows.count == 1)
    }

    @Test("Empty text shows no rows")
    func empty() {
        #expect(rows("  ").isEmpty)
    }

    // MARK: Bookmarks in the command bar

    @Test("A matching bookmark shows above matching history, because the user saved it on purpose")
    func bookmarkAboveHistory() {
        let bookmark = Bookmark(url: URL(string: "https://docs.swift.org/book")!, title: "The Swift Book")
        let result = rows("swift book", history: [visit("https://blog.example/swift-book", "Swift book review", count: 50)],
                          bookmarks: [bookmark])
        let bookmarkIndex = result.firstIndex(of: .bookmark(id: bookmark.id, title: bookmark.title, url: bookmark.url))
        let historyIndex = result.firstIndex { if case .history = $0 { true } else { false } }
        #expect(bookmarkIndex != nil && historyIndex != nil)
        #expect(bookmarkIndex! < historyIndex!)
    }

    @Test("A bookmarked page that is also in history shows once, as the bookmark")
    func bookmarkNotDuplicatedByHistory() {
        let bookmark = Bookmark(url: URL(string: "https://swift.org/")!, title: "Swift")
        let result = rows("swift language", history: [visit("https://swift.org", "Swift language", count: 5)],
                          bookmarks: [Bookmark(id: bookmark.id, url: bookmark.url, title: "Swift language")])
        #expect(result.contains(.bookmark(id: bookmark.id, title: "Swift language", url: bookmark.url)))
        #expect(!result.contains { if case .history = $0 { true } else { false } })
    }

    // MARK: Lists

    @Test("Search Tabs with no text lists every tab, so the user can browse without typing")
    func tabListShowsAllTabs() {
        let tabs: [SuggestionRanker.OpenTab] = [
            .init(id: UUID(), url: URL(string: "https://a.example")!, title: "A"),
            .init(id: UUID(), url: nil, title: ""),
            .init(id: UUID(), url: URL(string: "https://b.example")!, title: "B"),
        ]
        #expect(SuggestionRanker.tabRows(for: "", openTabs: tabs).count == 3)
    }

    @Test("Every word must match, so more words give fewer rows")
    func listNeedsEveryWord() {
        let tabs: [SuggestionRanker.OpenTab] = [.init(id: UUID(), url: URL(string: "https://git.example")!, title: "git")]
        #expect(SuggestionRanker.tabRows(for: "git", openTabs: tabs).count == 1)
        #expect(SuggestionRanker.tabRows(for: "git hub", openTabs: tabs).isEmpty)
    }

    @Test("History is newest first, even when an older page has more visits: it is a record of where the user was")
    func historyNewestFirst() {
        let result = SuggestionRanker.historyRows(for: "", history: [
            visit("https://often.example/", "Often", count: 100, daysAgo: 3),
            visit("https://once.example/", "Once", count: 1, daysAgo: 0),
        ])
        let titles = result.compactMap { row -> String? in
            if case .visit(let title, _, _) = row { return title } else { return nil }
        }
        #expect(titles == ["Once", "Often"])
    }

    @Test("Bookmarks keep the order the user added them in")
    func bookmarkListOrder() {
        let first = Bookmark(url: URL(string: "https://z.example")!, title: "Zed")
        let second = Bookmark(url: URL(string: "https://a.example")!, title: "Alpha")
        #expect(SuggestionRanker.bookmarkRows(for: "", bookmarks: [first, second]) == [
            .bookmark(id: first.id, title: "Zed", url: first.url),
            .bookmark(id: second.id, title: "Alpha", url: second.url),
        ])
    }

    // MARK: Search Commands

    let commands: [SuggestionRanker.MenuCommand] = [
        .init(title: "New Tab", menu: "File", shortcut: "⌘T", isEnabled: true),
        .init(title: "New Window", menu: "File", shortcut: "⌘N", isEnabled: true),
        .init(title: "Bookmark This Page", menu: "Bookmarks", shortcut: "⇧⌘B", isEnabled: false),
        .init(title: "Back", menu: "History", shortcut: "⌘[", isEnabled: true),
    ]

    func commandTitles(_ query: String) -> [String] {
        SuggestionRanker.commandRows(for: query, commands: commands).compactMap { row -> String? in
            if case .command(_, let title, _, _, _) = row { return title } else { return nil }
        }
    }

    @Test("Every word must match, so \"new window\" does not also give New Tab: Return runs the first row")
    func commandNeedsEveryWord() {
        #expect(commandTitles("new window") == ["New Window"])
    }

    @Test("The menu name matches too: the user looks for a command by its menu")
    func commandMatchesMenu() {
        #expect(commandTitles("history") == ["Back"])
    }

    @Test("Empty text lists every command in menu order, so the user can browse the menu bar")
    func commandListAll() {
        #expect(commandTitles("") == ["New Tab", "New Window", "Bookmark This Page", "Back"])
    }

    @Test("A command that is off stays in the list, marked off, and keeps its index into the menu items")
    func commandOffStays() {
        #expect(SuggestionRanker.commandRows(for: "bookmark", commands: commands) == [
            .command(index: 2, title: "Bookmark This Page", menu: "Bookmarks", shortcut: "⇧⌘B", isEnabled: false),
        ])
    }

    @Test("Shortcuts read as the menu bar shows them, so the user learns the real keys")
    func shortcutTexts() {
        // An uppercase key equivalent means Shift.
        #expect(SuggestionRanker.shortcutText(key: "T", control: false, option: false, shift: false, command: true) == "⇧⌘T")
        #expect(SuggestionRanker.shortcutText(key: "\t", control: true, option: false, shift: true, command: false) == "⌃⇧⇥")
        #expect(SuggestionRanker.shortcutText(key: "f", control: true, option: false, shift: false, command: true) == "⌃⌘F")
        #expect(SuggestionRanker.shortcutText(key: "b", control: false, option: true, shift: false, command: true) == "⌥⌘B")
        #expect(SuggestionRanker.shortcutText(key: "", control: false, option: false, shift: false, command: true) == "")
    }

    @Test("Day headers use calendar days, not 24-hour periods")
    func dayTitles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        // 22 h 50 min ago, but the same day.
        #expect(SuggestionRanker.dayTitle(for: date(23, 0, 10), now: date(23, 23, 0), calendar: calendar) == "Today")
        // Only 8 h 10 min ago, but the day before.
        #expect(SuggestionRanker.dayTitle(for: date(22, 23, 50), now: date(23, 8, 0), calendar: calendar) == "Yesterday")
        #expect(SuggestionRanker.dayTitle(for: date(21, 12, 0), now: date(23, 8, 0), calendar: calendar)
                .contains("21"))
    }
}
