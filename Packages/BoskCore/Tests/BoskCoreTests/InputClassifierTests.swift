import Foundation
import Testing
@testable import BoskCore

/// The command bar has one text field for both addresses and searches.
/// A wrong guess sends the user to a dead page or to a search they did not want.
struct InputClassifierTests {
    let google = URL(string: "https://www.google.com/search")!

    func url(_ input: String) -> String? {
        InputClassifier.url(for: input, searchURL: google)?.absoluteString
    }

    @Test("A typed domain opens over HTTPS, because most sites need it")
    func bareDomain() {
        #expect(url("x.com") == "https://x.com")
        #expect(url("news.ycombinator.com/item?id=1") == "https://news.ycombinator.com/item?id=1")
        #expect(url("  swift.org  ") == "https://swift.org")
    }

    @Test("Local dev servers and routers open over HTTP, because they rarely have HTTPS")
    func localAddresses() {
        #expect(url("localhost:3000") == "http://localhost:3000")
        #expect(url("localhost") == "http://localhost")
        #expect(url("192.168.1.1") == "http://192.168.1.1")
        #expect(url("10.0.0.2:8080/admin") == "http://10.0.0.2:8080/admin")
        #expect(url("[::1]:8080") == "http://[::1]:8080")
    }

    @Test("An explicit scheme is kept, so the user can force HTTP or open files")
    func explicitScheme() {
        #expect(url("http://example.com") == "http://example.com")
        #expect(url("file:///Users/me/a.html") == "file:///Users/me/a.html")
        #expect(url("about:blank") == "about:blank")
    }

    @Test("Words become a search, even when they contain a domain")
    func sentences() {
        #expect(url("what is x.com") == "https://www.google.com/search?q=what%20is%20x.com")
        #expect(url("foo.bar baz") == "https://www.google.com/search?q=foo.bar%20baz")
        #expect(url("weather") == "https://www.google.com/search?q=weather")
    }

    @Test("Text that only looks like an address becomes a search")
    func notAddresses() {
        #expect(url("1.5")?.hasPrefix("https://www.google.com/search") == true)
        #expect(url("999.1.1.1")?.hasPrefix("https://www.google.com/search") == true)
        #expect(url("javascript://alert(1)")?.hasPrefix("https://www.google.com/search") == true)
        #expect(url("host:notaport")?.hasPrefix("https://www.google.com/search") == true)
    }

    @Test("A plus sign in a search stays a plus sign, so 'c++' does not become 'c'")
    func plusIsEncoded() {
        #expect(url("c++ tutorial") == "https://www.google.com/search?q=c%2B%2B%20tutorial")
    }

    @Test("Empty input does nothing")
    func empty() {
        #expect(url("   ") == nil)
    }
}
