import AppKit

/// The shield in the top bar. A slashed shield: ads show on this page. Its menu turns the
/// ad blocker and the cookie notice blocker on or off everywhere, or on the site of the page shown.
@MainActor
final class AdBlockerButton: NSButton {
    private var url: URL?

    init() {
        super.init(frame: .zero)
        isBordered = false
        refusesFirstResponder = true
        symbolConfiguration = .init(pointSize: 14, weight: .medium)
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(showMenu)
        ContentBlocker.ads.addObserver(self) { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var fittingSize: NSSize { NSSize(width: 28, height: 28) }

    func update(for url: URL?) {
        self.url = url
        refresh()
    }

    private func refresh() {
        let site = ContentBlocker.site(for: url)
        let blocks = Preferences.blocksAds && site.map(ContentBlocker.ads.isAllowed) != true
        image = NSImage(systemSymbolName: blocks ? "shield" : "shield.slash",
                        accessibilityDescription: blocks ? "Ads blocked" : "Ads not blocked")
        toolTip = !Preferences.blocksAds ? "Ad blocker off" : blocks ? "Ads blocked" : "Ads allowed on this site"
    }

    @objc private func showMenu() {
        let site = ContentBlocker.site(for: url)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let everywhere = NSMenuItem(title: "Block Ads Everywhere",
                                    action: #selector(BrowserWindowController.toggleAdBlocker(_:)), keyEquivalent: "")
        everywhere.state = Preferences.blocksAds ? .on : .off
        menu.addItem(everywhere)
        let here = NSMenuItem(title: site.map { "Block Ads on \($0)" } ?? "Block Ads on This Site",
                              action: #selector(BrowserWindowController.toggleAdsOnSite(_:)), keyEquivalent: "")
        here.state = Preferences.blocksAds && site.map(ContentBlocker.ads.isAllowed) == false ? .on : .off
        here.isEnabled = Preferences.blocksAds && site != nil
        menu.addItem(here)
        menu.addItem(.separator())
        let cookiesEverywhere = NSMenuItem(title: "Hide Cookie Notices Everywhere",
                                           action: #selector(BrowserWindowController.toggleCookieNotices(_:)), keyEquivalent: "")
        cookiesEverywhere.state = Preferences.hidesCookieNotices ? .on : .off
        menu.addItem(cookiesEverywhere)
        let cookiesHere = NSMenuItem(title: site.map { "Hide Cookie Notices on \($0)" } ?? "Hide Cookie Notices on This Site",
                                     action: #selector(BrowserWindowController.toggleCookieNoticesOnSite(_:)), keyEquivalent: "")
        cookiesHere.state = Preferences.hidesCookieNotices && site.map(ContentBlocker.cookies.isAllowed) == false ? .on : .off
        cookiesHere.isEnabled = Preferences.hidesCookieNotices && site != nil
        menu.addItem(cookiesHere)
        // Nil target: the actions go to the window controller, which knows the tab to reload.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
    }
}
