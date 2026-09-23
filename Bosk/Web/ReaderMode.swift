import AppKit
import BoskCore
import WebKit

/// Reader mode. Defuddle finds the article on the page, Bosk saves it, and the tab goes to
/// a `bosk-reader:` page (see `ReaderPage`). That page is in the back/forward list, so Back
/// shows the original page, and a sleeping tab wakes up in the reader at the same place.
///
/// `Resources/Reader/defuddle.js` is Defuddle 0.19.4 (`dist/index.js` from npm, MIT license).
@MainActor
enum ReaderMode {
    nonisolated static let directory = Defaults.dataDirectory.appending(path: "Reader", directoryHint: .isDirectory)
    static let schemeHandler = ReaderSchemeHandler()

    private static let defuddle = Bundle.main.url(forResource: "defuddle", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    fileprivate static let style = Bundle.main.url(forResource: "reader", withExtension: "css")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    /// Runs in Bosk's script world, so the page cannot change Defuddle or read the result.
    private static let extractScript = """
        const result = new Defuddle(document, { url: location.href }).parse();
        return { title: result.title || document.title, author: result.author || '', site: result.site || '',
                 published: result.published || '', content: result.content || '', wordCount: result.wordCount || 0 };
        """

    static func isShowing(_ tab: Tab) -> Bool {
        tab.webView?.url.flatMap(ReaderPage.parse) != nil
    }

    /// Show Reader or Hide Reader, for the tab menus. Nil when the tab has no web page on screen.
    static func menuItem(for tab: Tab) -> NSMenuItem? {
        if isShowing(tab) { return ClosureMenuItem("Hide Reader") { hide(in: tab) } }
        guard let url = tab.webView?.url, ReaderPage.isWebPage(url) else { return nil }
        return ClosureMenuItem("Show Reader") { Task { await show(in: tab) } }
    }

    static func toggle(in tab: Tab) {
        if isShowing(tab) { hide(in: tab) } else { Task { await show(in: tab) } }
    }

    static func show(in tab: Tab) async {
        guard let webView = tab.webView, let page = webView.url, ReaderPage.isWebPage(page) else { return }
        guard let defuddle else { return showFailure(in: webView, "Bosk cannot find its reader script.") }
        let script = "if (typeof self.Defuddle !== 'function') {\n\(defuddle)\n}\n" + extractScript
        let result = try? await webView.callAsyncJavaScript(script, contentWorld: WebViewFactory.scriptWorld)
        guard let fields = result as? [String: Any], let content = fields["content"] as? String,
              (fields["wordCount"] as? Int ?? 0) > 0 else {
            return showFailure(in: webView, "Bosk found no article on this page.")
        }
        let article = ReaderPage.Article(title: fields["title"] as? String ?? "", author: fields["author"] as? String ?? "",
                                         site: fields["site"] as? String ?? "",
                                         published: displayDate(fields["published"] as? String ?? ""), content: content)
        let id = UUID()
        guard let url = ReaderPage.url(id: id, page: page) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(article).write(to: fileURL(for: id), options: .atomic)
        } catch {
            return showFailure(in: webView, "Bosk cannot save the article: \(error.localizedDescription)")
        }
        // The user may have gone to another page, or the tab may have slept, while Defuddle ran.
        guard tab.webView === webView, webView.url == page else { return }
        webView.load(URLRequest(url: url))
    }

    /// Goes back to the original page. Back when it is the page before the reader, so its
    /// scroll position and form text stay; otherwise it loads again.
    static func hide(in tab: Tab) {
        guard let webView = tab.webView, let page = webView.url.flatMap(ReaderPage.parse)?.page else { return }
        if webView.backForwardList.backItem?.url == page {
            webView.goBack()
        } else {
            webView.load(URLRequest(url: page))
        }
    }

    nonisolated static func fileURL(for id: UUID) -> URL {
        directory.appending(path: id.uuidString + ".json")
    }

    /// Deletes saved articles older than `Defaults.readerArticleLifetime`. A tab that still
    /// shows one opens the original page (see `ReaderPage.missingArticleHTML`).
    nonisolated static func deleteOldArticles() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let limit = Date().addingTimeInterval(-Defaults.readerArticleLifetime)
        for file in files {
            guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date < limit else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Defuddle gives ISO 8601 dates ("2023-07-01T00:00:00+00:00"); other text stays as it is.
    /// Only the date part, in UTC: a midnight time must not show as the day before here.
    private static func displayDate(_ text: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        guard let date = formatter.date(from: String(text.prefix(10))) else { return text }
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = .gmt
        return date.formatted(style)
    }

    private static func showFailure(in webView: WKWebView, _ text: String) {
        let alert = NSAlert()
        alert.messageText = "Reader cannot show this page"
        alert.informativeText = text
        if let window = webView.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Serves `bosk-reader:` pages from the saved articles.
@MainActor
final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let (id, page) = ReaderPage.parse(url) else {
            return task.didFailWithError(URLError(.badURL))
        }
        let html: String
        if let data = try? Data(contentsOf: ReaderMode.fileURL(for: id)),
           let article = try? JSONDecoder().decode(ReaderPage.Article.self, from: data) {
            html = ReaderPage.html(for: article, page: page, style: ReaderMode.style)
        } else {
            html = ReaderPage.missingArticleHTML(page: page)
        }
        // The article HTML comes from the web page. Page JavaScript is also off for this
        // scheme (see decidePolicyFor), so no script runs even if WebKit ignores this header.
        let headers = ["Content-Type": "text/html; charset=utf-8",
                       "Content-Security-Policy": "script-src 'none'; object-src 'none'; form-action 'none'"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return task.didFailWithError(URLError(.cannotParseResponse))
        }
        task.didReceive(response)
        task.didReceive(Data(html.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
