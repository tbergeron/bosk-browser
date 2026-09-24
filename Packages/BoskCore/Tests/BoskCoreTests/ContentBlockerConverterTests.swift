import Foundation
import Testing
@testable import BoskCore

/// The ad blocker must block ads and trackers, but a wrong rule breaks a site the user needs.
/// So a filter that WebKit cannot apply as written must be skipped, never made wider.
struct ContentBlockerConverterTests {
    typealias Converter = ContentBlockerConverter

    func matches(_ rule: Converter.Rule?, _ url: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: try #require(rule).trigger.urlFilter, options: .caseInsensitive)
        return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    @Test("||domain^ blocks the ad server and its subdomains, but not other sites that contain its name")
    func domainAnchor() throws {
        let rule = Converter.network("||ads.example.com^")
        #expect(try matches(rule, "https://ads.example.com/banner.js"))
        #expect(try matches(rule, "https://cdn.ads.example.com/x.png"))
        #expect(try !matches(rule, "https://notads.example.com/"))
        #expect(try !matches(rule, "https://site.com/?ref=ads.example.com.evil"))
        #expect(rule?.action.type == "block")
    }

    @Test("A block rule never blocks the page itself, because the user asked to open it")
    func neverBlocksThePage() throws {
        let rule = try #require(Converter.network("||tracker.example^"))
        #expect(rule.trigger.resourceType?.contains("document") == false)
    }

    @Test("$subdocument blocks ad frames only, not a page the user opens")
    func frames() throws {
        let rule = try #require(Converter.network("||adframe.example^$subdocument"))
        #expect(rule.trigger.resourceType == ["document"])
        #expect(rule.trigger.loadContext == ["child-frame"])
    }

    @Test("$third-party and $domain= become WebKit's load-type and if-domain, with subdomains")
    func options() throws {
        let rule = try #require(Converter.network("/ad.js$script,third-party,domain=news.com"))
        #expect(rule.trigger.loadType == ["third-party"])
        #expect(rule.trigger.resourceType == ["script"])
        #expect(rule.trigger.ifDomain == ["*news.com"])
    }

    @Test("Filters with options that WebKit cannot apply are skipped, because blocking without them breaks sites",
          arguments: ["||site.com/ads.js$redirect=noop.js", "||site.com^$removeparam=utm", "||site.com^$csp=script-src",
                      "/banner/$domain=a.com|~b.a.com", "/^https?:\\/\\/ad[0-9]\\./", "$script,third-party"])
    func unsupported(filter: String) {
        #expect(Converter.network(filter) == nil)
    }

    @Test("Exceptions come after blocks, because ignore-previous-rules cancels only earlier rules")
    func exceptionOrder() throws {
        let rules = Converter.rules(fromLists: ["@@||ads.example.com/ok.js", "||ads.example.com^"])
        #expect(rules.map(\.action.type) == ["block", "ignore-previous-rules"])
    }

    @Test("A generic hide rule does not apply on a site with an exception for it, so that site still works")
    func hideException() throws {
        let rules = Converter.rules(fromLists: ["##.ad-box", "shop.com#@#.ad-box", "##.sponsor", "#@#.sponsor"])
        #expect(rules.count == 1)
        #expect(rules[0].action == .init(type: "css-display-none", selector: ".ad-box"))
        #expect(rules[0].trigger.unlessDomain == ["*shop.com"])
    }

    @Test("Scriptlets and script-only selectors are skipped, not applied as broken CSS",
          arguments: ["site.com##+js(set-constant, ads, false)", "##div:has-text(Sponsored)",
                      "site.com#?#.ad:-abp-contains(Ad)", "site.com#$#abort-on-property-read ads", "site.com##^script"])
    func scriptOnly(filter: String) {
        #expect(Converter.rules(fromLists: [filter]).isEmpty)
    }

    @Test("A site the list or the user allows goes last, so its exception cancels every rule before it")
    func siteExceptionsLast() throws {
        let rules = Converter.rules(fromLists: ["@@||bank.com^$document", "##.ad", "||ads.example^"])
        #expect(rules.last?.action.type == "ignore-previous-rules")
        #expect(rules.last?.trigger.ifDomain == ["*bank.com"])

        let allow = Converter.allowRules(forSites: ["News.com", "not a domain"])
        #expect(allow == [.init(trigger: .init(urlFilter: ".*", ifDomain: ["*news.com"]),
                                action: .init(type: "ignore-previous-rules"))])
        #expect(Converter.allowRules(forSites: []).isEmpty)
    }

    @Test("The JSON uses WebKit's key names")
    func json() throws {
        let json = try Converter.json([try #require(Converter.network("||a.com^$third-party"))])
        #expect(json.contains("\"url-filter\":"))
        #expect(json.contains("\"load-type\":[\"third-party\"]"))
        #expect(!json.contains("ifDomain"))
    }
}
