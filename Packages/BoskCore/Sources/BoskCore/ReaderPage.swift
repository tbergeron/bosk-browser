import Foundation

/// Reader mode pages. An article is a real page at `bosk-reader://article/<id>?url=<page>`,
/// so it is in the tab's back/forward list, and WebKit loads it again (at the same scroll
/// position) when a sleeping tab wakes up.
public enum ReaderPage {
    public static let scheme = "bosk-reader"

    /// What Defuddle found on the page. Saved as JSON; the HTML is made each time it loads,
    /// so style changes apply to old articles too.
    public struct Article: Codable, Equatable, Sendable {
        public var title: String
        public var author: String
        public var site: String
        public var published: String
        /// Defuddle's cleaned HTML. It comes from the web page: show it only with page
        /// JavaScript off.
        public var content: String

        public init(title: String, author: String, site: String, published: String, content: String) {
            self.title = title
            self.author = author
            self.site = site
            self.published = published
            self.content = content
        }
    }

    /// - Returns: Nil when `page` is not an http or https page.
    public static func url(id: UUID, page: URL) -> URL? {
        guard isWebPage(page) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "article"
        components.path = "/" + id.uuidString
        // URLComponents does not encode "&" and "=" in query values, so encode all of it.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        components.percentEncodedQuery = "url=" + (page.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        return components.url
    }

    /// The article ID and the page it came from, or nil for other URLs.
    public static func parse(_ url: URL) -> (id: UUID, page: URL)? {
        guard url.scheme?.lowercased() == scheme, url.host() == "article",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = UUID(uuidString: String(components.path.dropFirst())),
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let page = URL(string: value), isWebPage(page) else { return nil }
        return (id, page)
    }

    /// The page the reader shows, or `url` itself when it is not a reader URL.
    /// The address bar, bookmarks and "Copy Address" use it.
    public static func pageURL(for url: URL) -> URL {
        parse(url)?.page ?? url
    }

    /// The reader's HTML document. `page` is the `<base>`, so relative links and images
    /// go to the original site.
    public static func html(for article: Article, page: URL, style: String) -> String {
        let byline = [article.author, article.published].filter { !$0.isEmpty }.map(escape).joined(separator: " · ")
        return """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="light dark">
            <base href="\(escape(page.absoluteString))">
            <title>\(escape(article.title))</title>
            <style>\(style)</style>
            </head>
            <body>
            <article>
            <header>
            \(article.site.isEmpty ? "" : "<p class=\"site\">\(escape(article.site))</p>")
            <h1>\(escape(article.title))</h1>
            \(byline.isEmpty ? "" : "<p class=\"byline\">\(byline)</p>")
            </header>
            \(article.content)
            </article>
            </body>
            </html>
            """
    }

    /// For a saved article that is gone: opens the original page. A meta refresh, because
    /// reader pages run no script.
    public static func missingArticleHTML(page: URL) -> String {
        "<!doctype html><meta http-equiv=\"refresh\" content=\"0; url=\(escape(page.absoluteString))\">"
    }

    /// Only web pages: a reader URL must not make Bosk open file:// or javascript: URLs.
    public static func isWebPage(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
