import Testing
@testable import BoskCore

/// The user zooms a site once and expects it to stay that way. All other sites must
/// stay at the default, even when the default changes later.
struct SiteZoomLevelsTests {
    @Test("A new site follows the default")
    func newSiteFollowsDefault() {
        let levels = SiteZoomLevels()
        #expect(levels.zoom(for: "example.com", defaultZoom: 1.25) == 1.25)
    }

    @Test("A zoomed site keeps its level when the default changes; other sites do not")
    func zoomedSiteIgnoresNewDefault() {
        var levels = SiteZoomLevels()
        levels.set(1.5, for: "example.com", defaultZoom: 1)
        #expect(levels.zoom(for: "example.com", defaultZoom: 2) == 1.5)
        #expect(levels.zoom(for: "other.com", defaultZoom: 2) == 2)
    }

    @Test("A site at 100% stays at 100% when the default is larger")
    func actualSizeIsAnAnswerWhenDefaultIsLarger() {
        var levels = SiteZoomLevels()
        levels.set(1, for: "example.com", defaultZoom: 1.25)
        #expect(levels.zoom(for: "example.com", defaultZoom: 1.25) == 1)
    }

    @Test("Zooming back to the default, or Cmd+0, makes the site follow the default again")
    func backToDefaultForgetsTheSite() {
        var levels = SiteZoomLevels(["a.com": 1.5, "b.com": 1.5])
        levels.set(1, for: "a.com", defaultZoom: 1)
        levels.set(nil, for: "b.com", defaultZoom: 1)
        #expect(levels.levels.isEmpty)
    }
}
