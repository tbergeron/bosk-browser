import Foundation
import Testing
@testable import BoskCore

/// Other apps (Aurel, scripts) drive Bosk through AppleScript. JavaScript in pages is behind
/// a switch that is off, so `set URL` must not be a second way to run it or to read files.
struct AppleScriptPageTests {
    @Test("A script loads web pages, because that is how automation opens a site")
    func webPages() {
        #expect(AppleScriptPage.url(from: "https://www.amazon.com/s?k=toothbrush")?.absoluteString
            == "https://www.amazon.com/s?k=toothbrush")
        #expect(AppleScriptPage.url(from: " http://localhost:3000 ")?.absoluteString == "http://localhost:3000")
        #expect(AppleScriptPage.url(from: "about:blank")?.absoluteString == "about:blank")
    }

    @Test("A javascript: URL is refused, so it cannot run JavaScript with the switch off")
    func noJavaScriptURL() {
        #expect(AppleScriptPage.url(from: "javascript:alert(document.cookie)") == nil)
        #expect(AppleScriptPage.url(from: "JavaScript:void(0)") == nil)
    }

    @Test("Files, data and other schemes are refused, so a script cannot show the user's files or forge a page")
    func noOtherSchemes() {
        #expect(AppleScriptPage.url(from: "file:///Users/me/.ssh/id_rsa") == nil)
        #expect(AppleScriptPage.url(from: "data:text/html,<script>1</script>") == nil)
        #expect(AppleScriptPage.url(from: "amazon.com") == nil)
        #expect(AppleScriptPage.url(from: "https://") == nil)
        #expect(AppleScriptPage.url(from: "") == nil)
    }

    @Test("Text comes back unchanged, because callers return JSON text and parse it")
    func textStays() {
        #expect(AppleScriptPage.value(#"{"ready":true}"#).stringValue == #"{"ready":true}"#)
    }

    @Test("Numbers and true/false keep their AppleScript types, as in Chrome")
    func numbers() {
        #expect(AppleScriptPage.value(3 as NSNumber).int32Value == 3)
        #expect(AppleScriptPage.value(2.5 as NSNumber).doubleValue == 2.5)
        #expect(AppleScriptPage.value(true as NSNumber).descriptorType == typeBoolean && AppleScriptPage.value(true as NSNumber).booleanValue)
    }

    @Test("Objects and arrays come back as JSON text, because AppleScript has no type for them")
    func objectsAsJSON() {
        #expect(AppleScriptPage.value(["a": 1]).stringValue == #"{"a":1}"#)
        #expect(AppleScriptPage.value([1, 2]).stringValue == "[1,2]")
    }

    @Test("undefined and null come back as missing value, not as an error")
    func nothing() {
        #expect(AppleScriptPage.value(nil).typeCodeValue == AppleScriptPage.missingValue)
        #expect(AppleScriptPage.value(NSNull()).typeCodeValue == AppleScriptPage.missingValue)
    }
}
