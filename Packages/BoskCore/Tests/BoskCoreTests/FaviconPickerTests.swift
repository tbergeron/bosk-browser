import Foundation
import Testing
@testable import BoskCore

/// Favicons are how the user finds tabs in the pinned grid and the folded strip.
/// A blurry or missing icon makes those views hard to use.
struct FaviconPickerTests {
    let page = URL(string: "https://github.com/apple/swift")!

    func candidate(_ path: String, _ sizes: String = "", rel: String = "icon") -> FaviconPicker.Candidate {
        .init(url: URL(string: "https://github.com" + path)!, sizes: sizes, rel: rel)
    }

    @Test("A 64 px or slightly larger icon wins, so tiles are sharp on 2x screens")
    func prefersSharpIcon() {
        let picked = FaviconPicker.pick(from: [
            candidate("/16.png", "16x16"),
            candidate("/64.png", "64x64"),
            candidate("/512.png", "512x512"),
        ], pageURL: page)
        #expect(picked?.lastPathComponent == "64.png")
    }

    @Test("With only small icons, the largest small icon wins")
    func largestSmallIcon() {
        let picked = FaviconPicker.pick(from: [candidate("/16.png", "16x16"), candidate("/32.png", "16x16 32x32")],
                                        pageURL: page)
        #expect(picked?.lastPathComponent == "32.png")
    }

    @Test("An apple-touch-icon without sizes counts as large, not as unknown")
    func touchIconBeatsUnknown() {
        let picked = FaviconPicker.pick(from: [candidate("/fav.png"),
                                               candidate("/touch.png", rel: "apple-touch-icon")],
                                        pageURL: page)
        #expect(picked?.lastPathComponent == "touch.png")
    }

    @Test("SVG icons are skipped, because NSImage cannot always draw them")
    func skipsSVG() {
        let picked = FaviconPicker.pick(from: [candidate("/logo.svg", "any")], pageURL: page)
        #expect(picked?.absoluteString == "https://github.com/favicon.ico")
    }

    @Test("A page with no declared icon falls back to /favicon.ico at its origin")
    func fallback() {
        let local = URL(string: "http://localhost:3000/app")!
        #expect(FaviconPicker.pick(from: [], pageURL: local)?.absoluteString == "http://localhost:3000/favicon.ico")
    }
}
