import BoskCore
import WebKit

/// The built-in ad blocker. It downloads EasyList and EasyPrivacy, converts them to WebKit rules
/// (ContentBlockerConverter) and adds the compiled list to the user content controller of all tabs.
/// On a site the user allows, each page load turns the list off with private WebKit API, so the
/// per-site switch needs no compile. Without that API, a site the user allows is a rule at the
/// end of the list, and a change to the allowed sites compiles the list again (a few seconds).
@MainActor
final class AdBlocker {
    static let shared = AdBlocker()

    private let directory = Defaults.dataDirectory.appending(path: "AdBlocker", directoryHint: .isDirectory)
    /// The converted lists, without the allowed sites. A new download replaces it.
    private var rulesFile: URL { directory.appending(path: "rules.json") }
    private lazy var store = WKContentRuleListStore(url: directory.appending(path: "Compiled", directoryHint: .isDirectory))!
    private let identifier = "Ads"
    /// The list on the tabs now. nil when the blocker is off or has no list yet.
    private var activeList: WKContentRuleList?
    private var isBuilding = false
    private var needsBuild = false
    /// Tab reloads that wait for the next list, after a change to the allowed sites.
    private var pendingReloads: [() -> Void] = []
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    /// When the lists were last downloaded. nil before the first download.
    var listsUpdated: Date? {
        (try? rulesFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func start() {
        load()
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                if Preferences.blocksAds && AdBlocker.shared.listsAreOld { AdBlocker.shared.build() }
            }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
    }

    /// - Parameter reload: Runs when the change is on the tabs, to show the page with the change.
    func setOn(_ on: Bool, reload: (() -> Void)? = nil) {
        Preferences.blocksAds = on
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

    /// Also true on a subdomain of an allowed site, because the allow rule covers subdomains.
    func allowsAds(on site: String) -> Bool {
        Preferences.adsAllowedSites.contains { site == $0 || site.hasSuffix("." + $0) }
    }

    /// - Parameter reload: Runs when the new list is on the tabs, to show the page with the change.
    func setAllowsAds(_ allowed: Bool, on site: String, reload: @escaping () -> Void) {
        var sites = Preferences.adsAllowedSites
        if allowed {
            sites.insert(site)
        } else {
            sites = sites.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        }
        Preferences.adsAllowedSites = sites
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

    /// For a page load in a main frame: turns this list off (and only this list, not the lists
    /// of extensions) when the user allows ads on the page's site.
    func configure(_ preferences: WKWebpagePreferences, for url: URL?) {
        guard let setRuleListsEnabled = Self.setRuleListsEnabled, Preferences.blocksAds,
              let site = Self.site(for: url), allowsAds(on: site) else { return }
        // All lists on, except the ones named in the exceptions.
        setRuleListsEnabled(preferences, Self.setRuleListsSelector, true, NSSet(object: identifier))
    }

    // MARK: Rule list

    /// Puts the saved list on the tabs at once, then builds a new list when there is none or it is old.
    private func load() {
        guard Preferences.blocksAds else { return }
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            MainActor.assumeIsolated {
                let blocker = AdBlocker.shared
                guard Preferences.blocksAds else { return }
                if let list, blocker.activeList == nil {
                    blocker.apply(list)
                    blocker.runPendingReloads()
                }
                if list == nil || blocker.listsAreOld { blocker.build() }
            }
        }
    }

    private var listsAreOld: Bool {
        listsUpdated.map { Date().timeIntervalSince($0) > Defaults.adListUpdateInterval } ?? true
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
                    NSLog("Bosk: ad blocker list did not build: %@", "\(error)")
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
        let sites = Self.setRuleListsEnabled == nil ? Array(Preferences.adsAllowedSites) : []
        let json = try await Task.detached(priority: .utility) {
            let rules = try String(contentsOf: rulesFile, encoding: .utf8)
            let allow = try ContentBlockerConverter.json(ContentBlockerConverter.allowRules(forSites: sites))
            // Both are JSON arrays. The allow rules must be last, so they cancel the rules before them.
            if allow == "[]" { return rules }
            if rules == "[]" { return allow }
            return rules.dropLast() + "," + allow.dropFirst()
        }.value
        guard let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json),
              Preferences.blocksAds else { return }
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
        for url in Defaults.adListURLs {
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
        // Remove only this list, never other rule lists on the controller.
        let controller = WebViewFactory.userContentController
        if let activeList { controller.remove(activeList) }
        if let list { controller.add(list) }
        activeList = list
    }
}
