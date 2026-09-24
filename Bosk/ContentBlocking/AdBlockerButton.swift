import AppKit

/// The shield in the top bar. A slashed shield: ads show on this page. Its menu turns the
/// ad blocker on or off everywhere, or on the site of the page shown.
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
        AdBlocker.shared.addObserver(self) { [weak self] in self?.refresh() }
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
        let site = AdBlocker.site(for: url)
        let blocks = Preferences.blocksAds && site.map(AdBlocker.shared.allowsAds) != true
        image = NSImage(systemSymbolName: blocks ? "shield" : "shield.slash",
                        accessibilityDescription: blocks ? "Ads blocked" : "Ads not blocked")
        toolTip = !Preferences.blocksAds ? "Ad blocker off" : blocks ? "Ads blocked" : "Ads allowed on this site"
    }

    @objc private func showMenu() {
        let site = AdBlocker.site(for: url)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let everywhere = NSMenuItem(title: "Block Ads Everywhere",
                                    action: #selector(BrowserWindowController.toggleAdBlocker(_:)), keyEquivalent: "")
        everywhere.state = Preferences.blocksAds ? .on : .off
        menu.addItem(everywhere)
        let here = NSMenuItem(title: site.map { "Block Ads on \($0)" } ?? "Block Ads on This Site",
                              action: #selector(BrowserWindowController.toggleAdsOnSite(_:)), keyEquivalent: "")
        here.state = Preferences.blocksAds && site.map(AdBlocker.shared.allowsAds) == false ? .on : .off
        here.isEnabled = Preferences.blocksAds && site != nil
        menu.addItem(here)
        // Nil target: the actions go to the window controller, which knows the tab to reload.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
    }
}
