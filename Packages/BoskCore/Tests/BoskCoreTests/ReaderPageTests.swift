import Foundation
import Testing
@testable import BoskCore

/// A reader tab must come back to the same article after sleep and relaunch, and its
/// address must stay the page the user opened. The article HTML comes from the web, so
/// the reader page must not give it a way to run script or open local files.
struct ReaderPageTests {
    let id = UUID()

    @Test("The page URL comes back exactly, with its query and fragment, so Hide Reader opens the same page")
    func roundTrip() throws {
        let page = URL(string: "https://example.com/a/b?x=1&y=a%20b&z=%26#part-2")!
        let url = try #require(ReaderPage.url(id: id, page: page))
        let parsed = try #require(ReaderPage.parse(url))
        #expect(parsed.id == id)
        #expect(parsed.page == page)
    }

    @Test("The address bar shows the original page, not the reader URL")
    func pageURLForAddressBar() throws {
        let page = URL(string: "https://example.com/story")!
        let url = try #require(ReaderPage.url(id: id, page: page))
        #expect(ReaderPage.pageURL(for: url) == page)
        #expect(ReaderPage.pageURL(for: page) == page)
    }

    @Test("Only web pages: a reader URL that points to file: or javascript: is not accepted")
    func rejectsLocalAndScriptURLs() throws {
        #expect(ReaderPage.url(id: id, page: URL(string: "file:///etc/passwd")!) == nil)
        let forged = try #require(URL(string: "bosk-reader://article/\(id.uuidString)?url=javascript%3Aalert(1)"))
        #expect(ReaderPage.parse(forged) == nil)
    }

    @Test("A URL without a valid article ID is not a reader page")
    func rejectsBadID() throws {
        let url = try #require(URL(string: "bosk-reader://article/nope?url=https%3A%2F%2Fexample.com"))
        #expect(ReaderPage.parse(url) == nil)
    }

    @Test("Page text in the title and byline cannot add markup to the reader page")
    func escapesMetadata() {
        let article = ReaderPage.Article(title: "<script>x()</script>", author: "A & B", site: "\"><img>",
                                         published: "", content: "<p>Body</p>")
        let html = ReaderPage.html(for: article, page: URL(string: "https://example.com/?a=\"b\"")!, style: "")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;x()&lt;/script&gt;"))
        #expect(html.contains("A &amp; B"))
        #expect(!html.contains("\"><img>"))
        #expect(html.contains("<base href=\"https://example.com/?a=%22b%22\">"))
        #expect(html.contains("<p>Body</p>"))
    }

    @Test("When the saved article is gone, the tab opens the original page instead of an empty one")
    func missingArticleOpensPage() {
        let html = ReaderPage.missingArticleHTML(page: URL(string: "https://example.com/a?b=1&c=2")!)
        #expect(html.contains("http-equiv=\"refresh\""))
        #expect(html.contains("url=https://example.com/a?b=1&amp;c=2\""))
    }

    @Test("An article with no author or date has no empty byline")
    func noEmptyByline() {
        let article = ReaderPage.Article(title: "T", author: "", site: "", published: "", content: "")
        let html = ReaderPage.html(for: article, page: URL(string: "https://example.com")!, style: "")
        #expect(!html.contains("byline"))
        #expect(!html.contains("class=\"site\""))
    }
}
