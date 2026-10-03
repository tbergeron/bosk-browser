import Foundation
import JavaScriptCore
import Testing
@testable import BoskCore

/// YouTube ads come from the same servers as the video, so only the page script can remove them.
/// The script must remove the ad data on every path that YouTube uses to give it to the player,
/// but it must keep the video data, or the video does not play. On a site where the user turned
/// the ad blocker off, and on all other sites, it must change nothing. When YouTube's video server
/// holds the video back for an ad that did not play, the script loads the video again once with a
/// changed request. More reloads stop the video, and a refused request must not leave it stuck.
struct YouTubeAdScriptTests {
    static let playerResponse = #"{"adPlacements":[1],"adSlots":[2],"playerAds":[3],"streamingData":{"formats":[]}}"#

    /// A JavaScriptCore context with the few page APIs that the script uses.
    func page(_ url: String, top: String? = nil, allowedSites: Set<String> = []) throws -> JSContext {
        let context = try #require(JSContext())
        let host = try #require(URL(string: url)?.host())
        context.evaluateScript("""
            var window = globalThis;
            class URL { constructor(text) { this.hostname = text.split('/')[2].split(':')[0]; } }
            var location = { hostname: '\(host)', ancestorOrigins: \(top.map { "['\($0)']" } ?? "[]") };
            class Response { constructor(text) { this.text = text; } }
            // WebKit's Response.json does not call the page's JSON.parse.
            const nativeParse = JSON.parse;
            Response.prototype.json = function () { return Promise.resolve(nativeParse(this.text)); };
            var setTimeout = (f) => f();
            // The YouTube player and its video server. `videoResponse` is the next response of the server.
            var loads = [];
            var player = { getVideoData: () => ({ video_id: 'abc' }), getCurrentTime: () => 12.5,
                           loadVideoById: (id, time) => loads.push([id, time]) };
            var document = { getElementById: (id) => id === 'movie_player' ? player : null };
            var videoResponse = [];
            var fetch = (url) => Promise.resolve({
              headers: { get: () => String(videoResponse.length) },
              clone: () => ({ arrayBuffer: () => Promise.resolve(Uint8Array.from(videoResponse).buffer) }),
            });
            var playerRequest = () => JSON.parse(JSON.stringify({ videoId: 'abc', attestationRequest: {},
              context: { client: { clientName: 'WEB' } },
              playbackContext: { contentPlaybackContext: { referer: 'https://www.youtube.com/watch?v=abc' } } }));
            """)
        context.evaluateScript(YouTubeAdScript.source(allowedSites: allowedSites))
        #expect(context.exception == nil)
        return context
    }

    func adKeys(_ context: JSContext, _ expression: String) -> [String] {
        context.evaluateScript("var value = \(expression);")
        let keys = context.evaluateScript("Object.keys(value)").toArray() as? [String] ?? []
        return keys.filter(YouTubeAdScript.adKeys.contains)
    }

    @Test("The watch page's ytInitialPlayerResponse has no ads, but keeps the video data")
    func initialResponse() throws {
        let context = try page("https://www.youtube.com/watch?v=x")
        context.evaluateScript("var ytInitialPlayerResponse = \(Self.playerResponse);")
        #expect(adKeys(context, "ytInitialPlayerResponse") == [])
        #expect(context.evaluateScript("'streamingData' in ytInitialPlayerResponse").toBool())
    }

    @Test("A video opened in the page (no reload) has no ads, from JSON.parse or from Response.json")
    func laterResponses() throws {
        let context = try page("https://www.youtube.com/")
        #expect(adKeys(context, "JSON.parse('\(Self.playerResponse)')") == [])
        #expect(adKeys(context, "JSON.parse('{\"playerResponse\":\(Self.playerResponse)}').playerResponse") == [])
        context.evaluateScript("new Response('\(Self.playerResponse)').json().then((v) => { window.fetched = v; });")
        #expect(adKeys(context, "fetched") == [])
        #expect(context.evaluateScript("'streamingData' in fetched").toBool())
    }

    @Test("A YouTube video in another site's page has no ads")
    func embed() throws {
        let context = try page("https://www.youtube-nocookie.com/embed/x", top: "https://news.example")
        #expect(adKeys(context, "JSON.parse('\(Self.playerResponse)')") == [])
    }

    @Test("When the user turns the ad blocker off on YouTube, the ads stay")
    func allowedSite() throws {
        let context = try page("https://www.youtube.com/watch?v=x", allowedSites: ["youtube.com"])
        #expect(adKeys(context, "JSON.parse('\(Self.playerResponse)')").count == 3)
    }

    @Test("When the user turns the ad blocker off on a site, the ads of its YouTube videos stay")
    func allowedEmbedSite() throws {
        let context = try page("https://www.youtube.com/embed/x", top: "https://www.news.example", allowedSites: ["news.example"])
        #expect(adKeys(context, "JSON.parse('\(Self.playerResponse)')").count == 3)
    }

    @Test("Other sites' data is not changed, even when it has the same field names")
    func otherSites() throws {
        for url in ["https://example.com/", "https://notyoutube.com/", "https://youtube.com.evil.example/"] {
            let context = try page(url)
            #expect(adKeys(context, "JSON.parse('\(Self.playerResponse)')").count == 3)
        }
    }

    /// UMP parts: the next request policy (35) with a 12 s backoff (field 4), and a message (67).
    static let backoff = [0x23, 0x03, 0x20, 0xE0, 0x5D, 0x43, 0x02, 0x08, 0x01]
    /// Video (20) and a next request policy with only a read-ahead time (field 1), as in a normal response.
    static let video = [0x14, 0x01, 0x00, 0x23, 0x03, 0x08, 0x98, 0x75]

    func serve(_ context: JSContext, _ bytes: [Int]) {
        context.evaluateScript("videoResponse = \(bytes); fetch('https://rr1.googlevideo.com/videoplayback?sabr=1');")
    }

    @Test("With no backoff, the player request is not changed, because a change can make YouTube refuse the video")
    func noChangeWithoutBackoff() throws {
        let context = try page("https://www.youtube.com/watch?v=abc")
        serve(context, Self.video)
        #expect(context.evaluateScript("loads.length").toInt32() == 0)
        #expect(context.evaluateScript("playerRequest().params === undefined").toBool())
    }

    @Test("After a backoff, the video loads again at the same time with the changed request, so it starts at once")
    func reloadAfterBackoff() throws {
        let context = try page("https://www.youtube.com/watch?v=abc")
        serve(context, Self.backoff)
        #expect(context.evaluateScript("JSON.stringify(loads)").toString() == #"[["abc",12.5]]"#)
        context.evaluateScript("var request = playerRequest();")
        #expect(context.evaluateScript("request.params").toString() == "8AUB")
        #expect(context.evaluateScript("request.playbackContext.contentPlaybackContext.referer.endsWith('#reloadxhr')").toBool())
    }

    @Test("Later backoffs cause no more reloads, because each reload stops the video")
    func oneReload() throws {
        let context = try page("https://www.youtube.com/watch?v=abc")
        serve(context, Self.backoff)
        serve(context, Self.backoff)
        #expect(context.evaluateScript("loads.length").toInt32() == 1)
    }

    @Test("When YouTube refuses the changed request, the video loads with the normal request and does not stay stuck")
    func refused() throws {
        let context = try page("https://www.youtube.com/watch?v=abc")
        serve(context, Self.backoff)
        context.evaluateScript(#"JSON.parse('{"responseContext":{},"playabilityStatus":{"status":"UNPLAYABLE"}}')"#)
        #expect(context.evaluateScript("loads.length").toInt32() == 2)
        #expect(context.evaluateScript("playerRequest().params === undefined").toBool())
        serve(context, Self.backoff)
        #expect(context.evaluateScript("loads.length").toInt32() == 2)
    }
}
