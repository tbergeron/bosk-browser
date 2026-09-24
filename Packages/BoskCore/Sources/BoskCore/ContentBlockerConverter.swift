import Foundation

/// Converts Adblock Plus filter lists (EasyList, EasyPrivacy) to WebKit content-blocker rules.
/// Only the basic filters: blocked addresses, their exceptions (`@@`) and hidden elements (`##`).
/// A filter that WebKit cannot apply as written is skipped, not guessed: a wrong rule can break a site.
public enum ContentBlockerConverter {
    public struct Rule: Codable, Equatable, Sendable {
        public struct Trigger: Codable, Equatable, Sendable {
            public var urlFilter: String
            public var urlFilterIsCaseSensitive: Bool?
            public var ifDomain: [String]?
            public var unlessDomain: [String]?
            public var loadType: [String]?
            public var resourceType: [String]?
            public var loadContext: [String]?

            enum CodingKeys: String, CodingKey {
                case urlFilter = "url-filter", urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
                case ifDomain = "if-domain", unlessDomain = "unless-domain", loadType = "load-type"
                case resourceType = "resource-type", loadContext = "load-context"
            }
        }

        public struct Action: Codable, Equatable, Sendable {
            public var type: String
            public var selector: String?
        }

        public var trigger: Trigger
        public var action: Action
    }

    /// The rules for all lists together. WebKit applies rules in order, and an exception
    /// (`ignore-previous-rules`) cancels only the rules before it. So the order is: blocks,
    /// then exceptions, then hidden elements, then sites where the list turns blocking off.
    public static func rules(fromLists lists: [String]) -> [Rule] {
        var blocks: [Rule] = [], exceptions: [Rule] = [], siteExceptions: [Rule] = []
        var genericHides: [String] = [], specificHides: [Rule] = []
        // Selector → domains where a generic hide rule must not apply (`site#@#selector`).
        var hideExceptions: [String: [String]] = [:]

        for list in lists {
            for line in list.split(whereSeparator: \.isNewline) {
                let filter = line.trimmingCharacters(in: .whitespaces)
                if filter.isEmpty || filter.hasPrefix("!") || filter.hasPrefix("[") { continue }
                if let hide = cosmetic(filter) {
                    switch hide {
                    case .generic(let selector): genericHides.append(selector)
                    case .specific(let rule): specificHides.append(rule)
                    case .exception(let selector, let domains): hideExceptions[selector, default: []] += domains
                    case .unsupported: break
                    }
                } else if let rule = network(filter) {
                    switch rule.action.type {
                    case "block": blocks.append(rule)
                    case _ where rule.trigger.urlFilter == ".*" && rule.trigger.resourceType == nil:
                        siteExceptions.append(rule)
                    default: exceptions.append(rule)
                    }
                }
            }
        }

        var hides: [Rule] = []
        for selector in genericHides {
            let excluded = hideExceptions[selector]
            // `#@#selector` with no site turns the generic rule off everywhere.
            if excluded?.contains("") == true { continue }
            hides.append(Rule(trigger: .init(urlFilter: ".*", unlessDomain: excluded),
                              action: .init(type: "css-display-none", selector: selector)))
        }
        return blocks + exceptions + hides + specificHides + siteExceptions
    }

    /// Rules that turn blocking off on these sites (and their subdomains). They go last.
    public static func allowRules(forSites sites: [String]) -> [Rule] {
        let domains = sites.compactMap(domain)
        guard !domains.isEmpty else { return [] }
        return [Rule(trigger: .init(urlFilter: ".*", ifDomain: domains.map { "*" + $0 }),
                     action: .init(type: "ignore-previous-rules"))]
    }

    public static func json(_ rules: [Rule]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(rules), as: UTF8.self)
    }

    // MARK: Element hiding

    enum Hide: Equatable {
        case generic(String)
        case specific(Rule)
        /// Domains are empty strings for an exception on every site.
        case exception(String, domains: [String])
        /// An element hiding filter that WebKit cannot apply. It is not a network filter either.
        case unsupported
    }

    /// Selectors that only uBlock or Adblock Plus scripts understand, not CSS.
    private static let scriptOnlySelectors = [
        ":-abp-", ":has-text(", ":contains(", ":xpath(", ":upward(", ":matches-css", ":matches-path(",
        ":matches-attr(", ":matches-prop(", ":min-text-length(", ":others(", ":remove", ":style(",
        ":watch-attr(", ":if(", ":if-not(", ":nth-ancestor(", ":spath(",
    ]

    /// nil when the filter is not an element hiding filter.
    static func cosmetic(_ filter: String) -> Hide? {
        // Extended filters (`#?#`, `#$#`, `#%#` and their `#@` exceptions) need scripts.
        if ["#?#", "#$#", "#%#", "#@?#", "#@$#", "#@%#"].contains(where: filter.contains) { return .unsupported }
        let isException: Bool
        let separator: Range<String.Index>
        if let range = filter.range(of: "#@#") {
            (isException, separator) = (true, range)
        } else if let range = filter.range(of: "##") {
            (isException, separator) = (false, range)
        } else {
            return nil
        }
        let selector = String(filter[separator.upperBound...])
        let sites = filter[..<separator.lowerBound]
        // `#?#`, `#$#`, `##+js(…)` and `##^` need scripts or HTML filtering: skipped.
        guard !selector.isEmpty, !selector.hasPrefix("+js("), !selector.hasPrefix("^"),
              !sites.contains("#"), selector.allSatisfy(\.isASCII),
              !scriptOnlySelectors.contains(where: selector.contains) else { return .unsupported }
        guard let domains = domainList(sites, separator: ",") else { return .unsupported }

        if isException {
            guard domains.unless.isEmpty else { return .unsupported }
            return .exception(selector, domains: domains.if.isEmpty ? [""] : domains.if.map { "*" + $0 })
        }
        if domains.if.isEmpty && domains.unless.isEmpty { return .generic(selector) }
        // WebKit does not allow if-domain and unless-domain in one rule.
        guard domains.if.isEmpty || domains.unless.isEmpty else { return .unsupported }
        return .specific(Rule(trigger: .init(urlFilter: ".*",
                                             ifDomain: domains.if.isEmpty ? nil : domains.if.map { "*" + $0 },
                                             unlessDomain: domains.unless.isEmpty ? nil : domains.unless.map { "*" + $0 }),
                              action: .init(type: "css-display-none", selector: selector)))
    }

    // MARK: Network filters

    /// nil when WebKit cannot apply the filter.
    static func network(_ filter: String) -> Rule? {
        var pattern = Substring(filter)
        let isException = pattern.hasPrefix("@@")
        if isException { pattern = pattern.dropFirst(2) }

        var options: [Substring] = []
        if let dollar = pattern.lastIndex(of: "$"),
           pattern[pattern.index(after: dollar)...].allSatisfy({ $0.isLetter || $0.isNumber || "~,=|.-_*".contains($0) }) {
            options = pattern[pattern.index(after: dollar)...].split(separator: ",")
            pattern = pattern[..<dollar]
        }
        // A pattern in slashes is a regular expression. WebKit supports only a small part of them.
        if pattern.count > 2 && pattern.hasPrefix("/") && pattern.hasSuffix("/") { return nil }

        var trigger = Rule.Trigger(urlFilter: "")
        var types: [String] = [], excludedTypes: [String] = []
        var isFrame = false, isDocument = false
        for option in options {
            let negated = option.hasPrefix("~")
            let name = (negated ? option.dropFirst() : option).lowercased()
            if name.hasPrefix("domain=") || name.hasPrefix("from=") {
                let value = name[name.index(after: name.firstIndex(of: "=")!)...]
                guard let domains = domainList(Substring(value), separator: "|"),
                      domains.if.isEmpty || domains.unless.isEmpty else { return nil }
                trigger.ifDomain = domains.if.isEmpty ? nil : domains.if.map { "*" + $0 }
                trigger.unlessDomain = domains.unless.isEmpty ? nil : domains.unless.map { "*" + $0 }
                continue
            }
            switch name {
            case "third-party", "3p": trigger.loadType = [negated ? "first-party" : "third-party"]
            case "first-party", "1p": trigger.loadType = [negated ? "third-party" : "first-party"]
            case "match-case": trigger.urlFilterIsCaseSensitive = true
            case "important", "all": break
            case "subdocument", "frame":
                if negated { excludedTypes.append("document") } else { isFrame = true }
            case "document", "doc":
                guard isException, !negated else { return nil }
                isDocument = true
            default:
                guard let type = resourceTypes[name] else { return nil }
                if negated { excludedTypes.append(type) } else { types.append(type) }
            }
        }

        // `@@||site^$document`: the list turns blocking off on that site.
        if isDocument {
            guard options.count == 1, pattern.hasPrefix("||"), pattern.hasSuffix("^"),
                  let site = domain(String(pattern.dropFirst(2).dropLast())) else { return nil }
            return Rule(trigger: .init(urlFilter: ".*", ifDomain: ["*" + site]), action: .init(type: "ignore-previous-rules"))
        }

        guard let urlFilter = urlFilter(for: pattern) else { return nil }
        // A rule for every address is only safe on the sites the filter names.
        if urlFilter == ".*" && trigger.ifDomain == nil { return nil }
        trigger.urlFilter = urlFilter

        if isFrame {
            // A frame is a document in a child frame. Other types in the same filter are separate.
            guard types.isEmpty else { return nil }
            trigger.resourceType = ["document"]
            trigger.loadContext = ["child-frame"]
        } else if !types.isEmpty {
            trigger.resourceType = types
        } else if !excludedTypes.isEmpty {
            trigger.resourceType = allResourceTypes.filter { !excludedTypes.contains($0) }
        } else {
            // With no type, WebKit also blocks the page itself. Adblock Plus never blocks the page.
            trigger.resourceType = allResourceTypes.filter { $0 != "document" }
        }
        return Rule(trigger: trigger, action: .init(type: isException ? "ignore-previous-rules" : "block"))
    }

    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
        "font": "font", "media": "media", "xmlhttprequest": "fetch", "xhr": "fetch", "ping": "ping",
        "websocket": "websocket", "other": "other", "popup": "popup", "object": "other",
    ]

    private static let allResourceTypes = ["image", "style-sheet", "script", "font", "media", "fetch",
                                           "ping", "websocket", "other", "document"]

    /// Adblock Plus address pattern → WebKit regular expression.
    static func urlFilter(for pattern: Substring) -> String? {
        guard pattern.allSatisfy(\.isASCII) else { return nil }
        var pattern = pattern
        var regex = ""
        if pattern.hasPrefix("||") {
            // The scheme, then the domain or any subdomain of it.
            regex = "^[^:]+://+([^:/]+\\.)?"
            pattern = pattern.dropFirst(2)
        } else if pattern.hasPrefix("|") {
            regex = "^"
            pattern = pattern.dropFirst()
        }
        let endsAtEnd = pattern.hasSuffix("|")
        if endsAtEnd { pattern = pattern.dropLast() }

        for character in pattern {
            switch character {
            case "*": regex += ".*"
            // The Adblock Plus separator: any character that is not a letter, a digit or one of `_-.%`.
            case "^": regex += "[^a-zA-Z0-9_.%-]"
            case ".", "+", "?", "$", "{", "}", "(", ")", "[", "]", "\\", "|": regex += "\\" + String(character)
            default: regex.append(character)
            }
        }
        if endsAtEnd { regex += "$" }
        // The filter matches anywhere in the address, so a leading or trailing `.*` does nothing.
        while regex.hasPrefix(".*") { regex.removeFirst(2) }
        while regex.hasSuffix(".*") && !regex.hasSuffix("\\.*") { regex.removeLast(2) }
        return regex.isEmpty ? ".*" : regex
    }

    // MARK: Domains

    /// `a.com,~b.a.com` → included and excluded domains. nil when one of them is not a plain domain.
    static func domainList(_ text: Substring, separator: Character) -> (if: [String], unless: [String])? {
        var included: [String] = [], excluded: [String] = []
        for entry in text.split(separator: separator) {
            let negated = entry.hasPrefix("~")
            guard let name = domain(String(negated ? entry.dropFirst() : entry)) else { return nil }
            if negated { excluded.append(name) } else { included.append(name) }
        }
        return (included, excluded)
    }

    /// A lowercase ASCII domain, or nil. Entries such as `google.*` or IDN names are not plain domains.
    static func domain(_ text: String) -> String? {
        let name = text.lowercased()
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !name.hasPrefix("."), !name.hasSuffix(".") else { return nil }
        return name
    }
}
