import Testing
@testable import BoskCore

/// A site's notification answer is saved with the origin WebKit gives (port 0 for the
/// default port) and read again with the tab's URL (port nil, or written out).
/// If the two keys differ, the site panel shows no switch, and "Off" does not stop the site.
struct SiteOriginTests {
    @Test("WebKit's port 0 and a URL with no port make the same key")
    func defaultPortForms() {
        let fromWebKit = SiteOrigin.key(scheme: "https", host: "app.slack.com", port: 0)
        let fromURL = SiteOrigin.key(scheme: "https", host: "app.slack.com", port: nil)
        let written = SiteOrigin.key(scheme: "https", host: "app.slack.com", port: 443)
        #expect(fromWebKit == "https://app.slack.com")
        #expect(fromURL == fromWebKit)
        #expect(written == fromWebKit)
    }

    @Test("Another port is another site: a local test server must not get the answer of the real site")
    func otherPortIsOtherOrigin() {
        #expect(SiteOrigin.key(scheme: "http", host: "localhost", port: 8000) == "http://localhost:8000")
        #expect(SiteOrigin.key(scheme: "http", host: "localhost", port: 8000)
            != SiteOrigin.key(scheme: "http", host: "localhost", port: nil))
        // 443 is the default for https only.
        #expect(SiteOrigin.key(scheme: "http", host: "example.com", port: 443) == "http://example.com:443")
    }

    @Test("Case does not make a different site")
    func caseIsIgnored() {
        #expect(SiteOrigin.key(scheme: "HTTPS", host: "Example.COM", port: nil) == "https://example.com")
    }
}
