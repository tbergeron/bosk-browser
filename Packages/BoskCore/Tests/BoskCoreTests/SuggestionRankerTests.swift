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
              history: [SuggestionRanker.HistoryItem] = []) -> [SuggestionRanker.Suggestion] {
        SuggestionRanker.suggestions(for: query, openTabs: tabs, history: history, now: now, searchURL: google)
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
            case .typed: false
            }
        }
        #expect(swiftRows.count == 1)
    }

    @Test("Empty text shows no rows")
    func empty() {
        #expect(rows("  ").isEmpty)
    }
}
