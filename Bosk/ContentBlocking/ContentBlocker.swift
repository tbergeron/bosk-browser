import BoskCore
import WebKit

/// A built-in blocker from filter lists: the ad blocker (EasyList and EasyPrivacy) and the cookie
/// notice blocker (EasyList Cookie). Each one downloads its lists, converts them to WebKit rules
/// (ContentBlockerConverter) and adds the compiled list to the user content controllers of all tabs.
/// On a site the user allows, each page load turns the list off with private WebKit API, so the
/// per-site switch needs no compile. Without that API, a site the user allows is a rule at the
/// end of the list, and a change to the allowed sites compiles the list again (a few seconds).
@MainActor
final class ContentBlocker {
    enum Kind {
        case ads, cookies
    }

    static let ads = ContentBlocker(.ads)
    static let cookies = ContentBlocker(.cookies)
    private static let all = [ads, cookies]

    let kind: Kind
    private let directory: URL
    /// The converted lists, without the allowed sites. A new download replaces it.
    private var rulesFile: URL { directory.appending(path: "rules.json") }
    private lazy var store = WKContentRuleListStore(url: directory.appending(path: "Compiled", directoryHint: .isDirectory))!
    private let identifier: String
    /// The list on the tabs now. nil when the blocker is off or has no list yet.
    private var activeList: WKContentRuleList?
    private var isBuilding = false
    private var needsBuild = false
    /// Tab reloads that wait for the next list, after a change to the allowed sites.
    private var pendingReloads: [() -> Void] = []
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    private init(_ kind: Kind) {
        self.kind = kind
        switch kind {
        case .ads:
            identifier = "Ads"
            // The name from before the cookie notice blocker, so the saved list stays in use.
            directory = Defaults.dataDirectory.appending(path: "AdBlocker", directoryHint: .isDirectory)
        case .cookies:
            identifier = "CookieNotices"
            directory = Defaults.dataDirectory.appending(path: "CookieNotices", directoryHint: .isDirectory)
        }
    }

    private var listURLs: [URL] {
        switch kind {
        case .ads: Defaults.adListURLs
        case .cookies: Defaults.cookieListURLs
        }
    }

    var isOn: Bool {
        get {
            switch kind {
            case .ads: Preferences.blocksAds
            case .cookies: Preferences.hidesCookieNotices
            }
        }
        set {
            switch kind {
            case .ads: Preferences.blocksAds = newValue
            case .cookies: Preferences.hidesCookieNotices = newValue
            }
        }
    }

    private var allowedSites: Set<String> {
        get {
            switch kind {
            case .ads: Preferences.adsAllowedSites
            case .cookies: Preferences.cookieNoticesShownSites
            }
        }
        set {
            switch kind {
            case .ads: Preferences.adsAllowedSites = newValue
            case .cookies: Preferences.cookieNoticesShownSites = newValue
            }
        }
    }

    /// The allowed sites of the private windows: the saved sites, with the changes made in a
    /// private window. nil when there is no change. In memory only; see `endPrivateSession`.
    private var privateAllowedSites: Set<String>?

    /// The per-site switch works in private windows only with the per-page WebKit API: without
    /// it, the allowed sites are in the one list that all windows share.
    static var canChangeSitesInPrivate: Bool { setRuleListsEnabled != nil }

    /// The last private window closed: private windows forget their changes.
    static func endPrivateSession() {
        for blocker in all { blocker.privateAllowedSites = nil }
    }

    /// When the lists were last downloaded. nil before the first download.
    var listsUpdated: Date? {
        (try? rulesFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func start() {
        load()
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                if isOn && listsAreOld { build() }
            }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
    }

    /// - Parameter reload: Runs when the change is on the tabs, to show the page with the change.
    func setOn(_ on: Bool, reload: (() -> Void)? = nil) {
        isOn = on
        if let reload { pendingReloads.append(reload) }
        if on {
            load()
        } else {
            apply(nil)
            runPendingReloads()
        }
        changed()
    }

    /// The handler runs after each change: the switches, or new lists.
    func addObserver(_ owner: AnyObject, _ handler: @escaping () -> Void) {
        observers[ObjectIdentifier(owner)] = handler
    }

    private func changed() {
        observers.values.forEach { $0() }
    }

    // MARK: Sites

    /// The site of a page for the per-site switch: its host without `www.`. nil for other pages.
    static func site(for url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme ?? ""), var host = url.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// True when the user turned this blocker off on the site. Also true on a subdomain of an
    /// allowed site, because the allow rule covers subdomains.
    func isAllowed(on site: String, isPrivate: Bool = false) -> Bool {
        let sites = isPrivate ? privateAllowedSites ?? allowedSites : allowedSites
        return sites.contains { site == $0 || site.hasSuffix("." + $0) }
    }

    /// - Parameters:
    ///   - isPrivate: A change in a private window. It is not saved, and normal windows do not get it.
    ///   - reload: Runs when the new list is on the tabs, to show the page with the change.
    func setAllowed(_ allowed: Bool, on site: String, isPrivate: Bool = false, reload: @escaping () -> Void) {
        guard !isPrivate || Self.canChangeSitesInPrivate else { return }
        var sites = isPrivate ? privateAllowedSites ?? allowedSites : allowedSites
        if allowed {
            sites.insert(site)
        } else {
            sites = sites.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        }
        if isPrivate {
            privateAllowedSites = sites
            reload()
            return changed()
        }
        allowedSites = sites
        if Self.setRuleListsEnabled != nil {
            reload()
        } else {
            pendingReloads.append(reload)
            build()
        }
        changed()
    }

    // MARK: Per-page switch (private WebKit API)

    private typealias SetRuleListsEnabled = @convention(c) (AnyObject, Selector, Bool, NSSet) -> Void
    private static let setRuleListsSelector = NSSelectorFromString("_setContentRuleListsEnabled:exceptions:")
    /// WebKit's own per-page switch, as Safari uses for a site. Private, so a macOS update can remove
    /// it: nil then, and the allowed sites go in the list instead.
    private static let setRuleListsEnabled: SetRuleListsEnabled? = {
        // The types must be (Bool, object) as tested, or a call with other types can crash.
        guard let method = class_getInstanceMethod(WKWebpagePreferences.self, setRuleListsSelector),
              let types = method_getTypeEncoding(method), String(cString: types) == "v28@0:8B16@20" else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: SetRuleListsEnabled.self)
    }()

    /// For a page load in a main frame: turns off the lists of the blockers that the user turned
    /// off on the page's site (and only those, not the lists of extensions). One call for all
    /// blockers, because each call replaces the exceptions of the call before it.
    static func configure(_ preferences: WKWebpagePreferences, for url: URL?, isPrivate: Bool) {
        guard let setRuleListsEnabled, let site = site(for: url) else { return }
        let exceptions = all.filter { $0.isOn && $0.isAllowed(on: site, isPrivate: isPrivate) }.map(\.identifier)
        guard !exceptions.isEmpty else { return }
        // All lists on, except the ones named in the exceptions.
        setRuleListsEnabled(preferences, setRuleListsSelector, true, NSSet(array: exceptions))
    }

    // MARK: Rule list

    /// Puts the saved list on the tabs at once, then builds a new list when there is none or it is old.
    private func load() {
        guard isOn else { return }
        store.lookUpContentRuleList(forIdentifier: identifier) { [self] list, _ in
            MainActor.assumeIsolated {
                guard isOn else { return }
                if let list, activeList == nil {
                    apply(list)
                    runPendingReloads()
                }
                if list == nil || listsAreOld { build() }
            }
        }
    }

    private var listsAreOld: Bool {
        listsUpdated.map { Date().timeIntervalSince($0) > Defaults.filterListUpdateInterval } ?? true
    }

    /// One build at a time. A request during a build makes one more build after it.
    private func build() {
        needsBuild = true
        guard !isBuilding else { return }
        isBuilding = true
        Task {
            while needsBuild {
                needsBuild = false
                do {
                    try await buildOnce()
                } catch {
                    NSLog("Bosk: %@ list did not build: %@", identifier, "\(error)")
                    pendingReloads.removeAll()
                }
            }
            isBuilding = false
        }
    }

    private func buildOnce() async throws {
        if listsAreOld {
            try await downloadLists()
            changed()
        }
        let rulesFile = rulesFile
        let sites = Self.setRuleListsEnabled == nil ? Array(allowedSites) : []
        let json = try await Task.detached(priority: .utility) {
            let rules = try String(contentsOf: rulesFile, encoding: .utf8)
            let allow = try ContentBlockerConverter.json(ContentBlockerConverter.allowRules(forSites: sites))
            // Both are JSON arrays. The allow rules must be last, so they cancel the rules before them.
            if allow == "[]" { return rules }
            if rules == "[]" { return allow }
            return rules.dropLast() + "," + allow.dropFirst()
        }.value
        guard let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json),
              isOn else { return }
        apply(list)
        runPendingReloads()
    }

    private func runPendingReloads() {
        let reloads = pendingReloads
        pendingReloads.removeAll()
        reloads.forEach { $0() }
    }

    /// Downloads the lists and saves them converted. A cookie-free session, so the list server
    /// learns nothing about the user but the address the request comes from.
    private func downloadLists() async throws {
        let session = URLSession(configuration: .ephemeral)
        var lists: [String] = []
        for url in listURLs {
            let (data, response) = try await session.data(from: url)
            let text = String(decoding: data, as: UTF8.self)
            // An error page or a Wi-Fi sign-in page is not a list.
            guard (response as? HTTPURLResponse)?.statusCode == 200, text.hasPrefix("[Adblock Plus") else {
                throw URLError(.cannotParseResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])
            }
            lists.append(text)
        }
        let directory = directory, rulesFile = rulesFile
        try await Task.detached(priority: .utility) {
            let json = try ContentBlockerConverter.json(ContentBlockerConverter.rules(fromLists: lists))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try json.write(to: rulesFile, atomically: true, encoding: .utf8)
        }.value
    }

    private func apply(_ list: WKContentRuleList?) {
        // Remove only this list, never other rule lists on the controllers.
        for controller in WebViewFactory.userContentControllers {
            if let activeList { controller.remove(activeList) }
            if let list { controller.add(list) }
        }
        activeList = list
    }
}
