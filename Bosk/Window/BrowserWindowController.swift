import AppKit
import BoskCore
import WebKit

/// One browser window: the sidebar on the left, and a rounded card with the top bar
/// and the web content on the right. The content goes up under a transparent title bar,
/// so the sidebar owns the space next to the window buttons.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let store = TabStore()
    private let topBar = TopBar()
    private let container = WebContainerView()
    private let findBar = FindBar()
    private let extensionActions = ExtensionActionsView()
    private let addToBoskButton = AddToBoskButton()
    private let adBlockerButton = AdBlockerButton()
    private let sidebar: SidebarView
    private let rootView: RootView
    private lazy var commandBar = CommandBarPanel()
    /// "New Tab in Group": the group of the tab the open command bar makes.
    private var newTabGroupID: UUID?

    init(restoring state: WindowState? = nil) {
        sidebar = SidebarView(store: store)
        rootView = RootView(sidebar: sidebar, topBar: topBar, container: container, findBar: findBar)
        let window = BoskWindow(
            contentRect: NSRect(origin: .zero, size: Defaults.initialWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Until a tab is on screen. See tabStore(_:didSelect:previous:).
        window.title = "New Tab"
        window.minSize = Defaults.minimumWindowSize
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        super.init(window: window)
        window.delegate = self

        topBar.onAddressClick = { [weak self] in self?.openLocation(nil) }
        sidebar.onNewTab = { [weak self] in self?.showCommandBar(target: .newTab) }
        sidebar.onNewTabInGroup = { [weak self] id in self?.showCommandBar(target: .newTab, group: id) }
        sidebar.onToggleFold = { [weak self] in self?.toggleSidebarFold(nil) }
        rootView.onDragFold = { [weak self] folded in self?.setSidebarFolded(folded, animated: true) }
        store.delegate = self
        store.window = window
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        extensionActions.currentTab = { [weak self] in self?.store.selectedTab }
        topBar.setAccessoryViews([UpdateButton(), addToBoskButton, adBlockerButton, TopBarDivider(), extensionActions, DownloadsButton()])
        ExtensionManager.shared.addObserver(self) { [weak self] in self?.extensionActions.reload() }
        NotificationCenter.default.addObserver(forName: PageZoom.didChangeDefault, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                for tab in self?.store.allTabs ?? [] where tab.zoomOverride == nil {
                    tab.webView?.pageZoom = PageZoom.defaultZoom
                }
            }
        }
        NotificationCenter.default.addObserver(forName: Preferences.hidesSidebarDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rootView.setSidebarHidden(Preferences.hidesSidebar) }
        }

        if let frame = state?.frame, frame.count == 4 {
            window.setFrame(NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]), display: false)
        } else {
            window.center()
        }
        if state?.sidebarFolded == true { setSidebarFolded(true, animated: false) }
        if let state { store.restore(state) } else { store.syncPinnedTabs() }
        sidebar.reloadTabs()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var windowState: WindowState {
        let frame = window.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height].map(Double.init) }
        return store.windowState(frame: frame, sidebarFolded: rootView.isSidebarFolded)
    }

    // MARK: Command bar

    /// - Parameter group: A new tab from the bar goes at the end of this group.
    func showCommandBar(target: CommandBarPanel.Target, mode: CommandBarPanel.Mode = .open, group: UUID? = nil) {
        guard let window else { return }
        newTabGroupID = group
        let text = target == .currentTab ? (store.selectedTab?.url?.absoluteString ?? "") : ""
        // Read the menu bar while this window is still key, so each item's on/off state is for this window.
        let menuItems = mode == .commands ? MainMenu.commands() : []
        let commands = menuItems.map {
            SuggestionRanker.MenuCommand(title: $0.item.title, menu: $0.menu,
                                         shortcut: MainMenu.shortcut(of: $0.item), isEnabled: $0.item.isEnabled)
        }
        commandBar.present(over: window, text: text, target: target, mode: mode, provider: { text in
            await Self.rows(for: text, mode: mode, commands: commands)
        }, onChoose: { [weak self] choice, target in
            if case .command(let index, _, _, _, _) = choice {
                self?.run(menuItems[index].item)
            } else {
                self?.choose(choice, target: target)
            }
        }, onRemove: { choice in
            switch choice {
            case .visit(_, let url, _): await HistoryStore.shared.remove(url: url)
            case .bookmark(let id, _, _): BookmarkStore.shared.remove(id: id)
            case .typed, .openTab, .history, .command: break
            }
        })
    }

    /// Runs a menu bar item as the menu would: its own target (a bookmark, a window in the
    /// Window menu), or else the responder chain of this window. The item is the sender,
    /// so Tab 1…9 get their tag.
    private func run(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        window?.makeKeyAndOrderFront(nil)
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func rows(for text: String, mode: CommandBarPanel.Mode,
                             commands: [SuggestionRanker.MenuCommand]) async -> [CommandBarPanel.Row] {
        let openTabs = (NSApp.delegate as? AppDelegate)?.allTabs.map {
            SuggestionRanker.OpenTab(id: $0.id, url: $0.url, title: $0.title)
        } ?? []
        switch mode {
        case .open:
            let history = await HistoryStore.shared.candidates(for: text)
            return SuggestionRanker.suggestions(for: text, openTabs: openTabs, history: history,
                                                bookmarks: BookmarkStore.shared.entries,
                                                now: Date(), searchURL: Defaults.searchURL).map { .item($0) }
        case .tabs:
            return section("Open Tabs", SuggestionRanker.tabRows(for: text, openTabs: openTabs))
        case .bookmarks:
            return section("Bookmarks", SuggestionRanker.bookmarkRows(for: text, bookmarks: BookmarkStore.shared.entries))
        case .history:
            let visits = SuggestionRanker.historyRows(for: text, history: await HistoryStore.shared.visits(for: text))
            // One header for each day ("Today", "Yesterday", …). The rows are newest first.
            let now = Date()
            var rows: [CommandBarPanel.Row] = []
            var day: String?
            for visit in visits {
                guard case .visit(_, _, let lastVisit) = visit else { continue }
                let title = SuggestionRanker.dayTitle(for: lastVisit, now: now)
                if title != day { rows.append(.header(title)) }
                day = title
                rows.append(.item(visit))
            }
            return rows
        case .commands:
            // One header for each menu ("File", "View", …), in menu bar order.
            var rows: [CommandBarPanel.Row] = []
            var menu: String?
            for command in SuggestionRanker.commandRows(for: text, commands: commands) {
                guard case .command(_, _, let commandMenu, _, _) = command else { continue }
                if commandMenu != menu { rows.append(.header(commandMenu)) }
                menu = commandMenu
                rows.append(.item(command))
            }
            return rows
        }
    }

    private static func section(_ title: String, _ items: [SuggestionRanker.Suggestion]) -> [CommandBarPanel.Row] {
        items.isEmpty ? [] : [.header(title)] + items.map { .item($0) }
    }

    private func choose(_ choice: SuggestionRanker.Suggestion, target: CommandBarPanel.Target) {
        switch choice {
        case .typed(let url), .history(_, let url), .bookmark(_, _, let url), .visit(_, let url, _):
            if target == .currentTab, let tab = store.selectedTab {
                tab.load(url)
            } else {
                store.newTab(url: url, inGroup: newTabGroupID)
            }
            focusWebView()
        case .openTab(let id, _, _):
            (NSApp.delegate as? AppDelegate)?.showTab(id: id)
        case .command:
            break  // Run in showCommandBar, which has the menu items.
        }
    }

    private func focusWebView() {
        if let webView = store.selectedTab?.webView { window?.makeFirstResponder(webView) }
    }

    // MARK: Sidebar

    // MARK: Extensions

    func extensionActionsChanged(for context: WKWebExtensionContext) {
        extensionActions.reload(context)
    }

    func presentPopup(for action: WKWebExtension.Action, of context: WKWebExtensionContext) {
        guard let popover = action.popupPopover else { return }
        let anchor = extensionActions.button(for: context) ?? topBar
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    // MARK: Find

    private func hideFindBar() {
        rootView.setFindBarVisible(false)
        focusWebView()
    }

    // MARK: Sidebar

    func setSidebarFolded(_ folded: Bool, animated: Bool) {
        rootView.setSidebarFolded(folded, animated: animated)
        SessionStore.shared.setNeedsSave()
    }

    // MARK: Menu actions (reached through the responder chain)

    @objc func newTab(_ sender: Any?) { showCommandBar(target: .newTab) }
    @objc func openLocation(_ sender: Any?) {
        showCommandBar(target: store.selectedTab == nil ? .newTab : .currentTab)
    }
    /// A window with only pinned tabs closes: closing a pinned tab only resets it.
    @objc func closeTab(_ sender: Any?) {
        if let tab = store.selectedTab, !(tab.isPinned && store.tabs.isEmpty) {
            store.close(tab)
        } else {
            window?.performClose(sender)
        }
    }
    @objc func reopenClosedTab(_ sender: Any?) { store.reopenClosedTab() }
    @objc func browserBack(_ sender: Any?) { store.selectedTab?.webView?.goBack() }
    @objc func browserForward(_ sender: Any?) { store.selectedTab?.webView?.goForward() }
    @objc func browserReload(_ sender: Any?) { store.selectedTab?.webView?.reload() }
    @objc func browserStop(_ sender: Any?) { store.selectedTab?.webView?.stopLoading() }
    // NSWindow has actions named selectNextTab:, selectPreviousTab: and toggleSidebar:, and it is
    // before this controller in the responder chain. It takes those menu items and disables them,
    // so these actions have other names.
    @objc func showNextTab(_ sender: Any?) { store.selectNeighbor(offset: 1) }
    @objc func showPreviousTab(_ sender: Any?) { store.selectNeighbor(offset: -1) }
    /// Cmd+1…8 select that tab; Cmd+9 selects the last tab (as in other browsers).
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        if sender.tag == 9 { store.select(at: store.allTabs.count - 1) } else { store.select(at: sender.tag - 1) }
    }
    @objc func toggleSidebarFold(_ sender: Any?) {
        setSidebarFolded(!rootView.isSidebarFolded, animated: true)
    }
    /// For all windows (View > Hide Sidebar, ⇧⌘S).
    @objc func toggleHidesSidebar(_ sender: Any?) { Preferences.hidesSidebar.toggle() }
    @objc func showFindBar(_ sender: Any?) {
        guard store.selectedTab?.webView != nil else { return }
        findBar.webView = store.selectedTab?.webView
        rootView.setFindBarVisible(true)
        findBar.focus()
    }
    @objc func findNext(_ sender: Any?) { findBar.findNext() }
    @objc func findPrevious(_ sender: Any?) { findBar.findPrevious() }
    @objc func printPage(_ sender: Any?) {
        guard let webView = store.selectedTab?.webView, let window else { return }
        let operation = webView.printOperation(with: .shared)
        // WebKit's print view needs a frame, or the print preview is empty.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
    @objc func zoomIn(_ sender: Any?) { changeZoom(larger: true) }
    @objc func zoomOut(_ sender: Any?) { changeZoom(larger: false) }
    @objc func actualSize(_ sender: Any?) { store.selectedTab?.zoomOverride = nil }

    private func changeZoom(larger: Bool) {
        guard let tab = store.selectedTab else { return }
        let next = PageZoom.next(after: tab.zoomOverride ?? PageZoom.defaultZoom, larger: larger)
        tab.zoomOverride = abs(next - PageZoom.defaultZoom) < 0.001 ? nil : next
    }

    @objc func searchTabs(_ sender: Any?) { showCommandBar(target: .newTab, mode: .tabs) }
    @objc func showHistory(_ sender: Any?) { showCommandBar(target: .newTab, mode: .history) }
    @objc func showBookmarks(_ sender: Any?) { showCommandBar(target: .newTab, mode: .bookmarks) }
    @objc func searchCommands(_ sender: Any?) { showCommandBar(target: .newTab, mode: .commands) }

    /// Bookmarks the page, or removes its bookmark if it has one. Removing asks first:
    /// nothing is deleted without a question.
    @objc func bookmarkPage(_ sender: Any?) {
        guard let tab = store.selectedTab, let url = tab.url else { return }
        if let bookmark = BookmarkStore.shared.bookmark(for: url) {
            let name = bookmark.title.isEmpty ? url.absoluteString : bookmark.title
            guard confirm("Remove this bookmark?", "Bosk removes “\(name)” from Bookmarks.",
                          button: "Remove Bookmark") else { return }
            BookmarkStore.shared.remove(id: bookmark.id)
        } else {
            BookmarkStore.shared.add(url: url, title: tab.title)
        }
    }

    @objc func toggleReader(_ sender: Any?) {
        guard let tab = store.selectedTab else { return }
        ReaderMode.toggle(in: tab)
    }

    /// From the shield menu in the top bar. The page reloads when the change is on the tabs.
    @objc func toggleAdBlocker(_ sender: Any?) {
        let tab = store.selectedTab
        AdBlocker.shared.setOn(!Preferences.blocksAds) { [weak tab] in tab?.webView?.reload() }
    }

    @objc func toggleAdsOnSite(_ sender: Any?) {
        guard let tab = store.selectedTab, let site = AdBlocker.site(for: tab.url) else { return }
        AdBlocker.shared.setAllowsAds(!AdBlocker.shared.allowsAds(on: site), on: site) { [weak tab] in
            tab?.webView?.reload()
        }
    }

    @objc func togglePinTab(_ sender: Any?) {
        guard let tab = store.selectedTab else { return }
        if tab.isPinned { store.unpin(tab) } else { store.pin(tab) }
    }
    /// The current tab, and the tabs Cmd+clicked in the sidebar.
    @objc func addTabToNewGroup(_ sender: Any?) {
        guard let tab = store.selectedTab, !tab.isPinned else { return }
        sidebar.addToNewGroup(sidebar.selectedTabs)
    }
    @objc func removeTabFromGroup(_ sender: Any?) {
        guard let tab = store.selectedTab else { return }
        store.removeFromGroup(tab)
    }

    func windowDidMove(_ notification: Notification) { SessionStore.shared.setNeedsSave() }
    func windowDidBecomeKey(_ notification: Notification) { ExtensionManager.shared.controller.didFocusWindow(self) }
    func windowDidEndLiveResize(_ notification: Notification) { SessionStore.shared.setNeedsSave() }

    /// Close Window, Cmd+Shift+W and the close button ask first when the window has tabs:
    /// its closed tabs go with the window, so Reopen Closed Tab cannot get them back.
    /// Pinned tabs do not count (every window shows them), and Quit does not come here
    /// (the session keeps the tabs).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let count = store.tabs.count
        guard count > 0 else { return true }
        return confirm("Close this window?",
                       count == 1 ? "Its tab closes. You cannot reopen it." : "Its \(count) tabs close. You cannot reopen them.",
                       button: "Close Window")
    }

    private func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        for tab in store.allTabs {
            ExtensionManager.shared.didClose(tab, windowIsClosing: true)
            tab.close()
        }
        ExtensionManager.shared.controller.didCloseWindow(self)
        (NSApp.delegate as? AppDelegate)?.windowControllerDidClose(self)
    }
}

extension BrowserWindowController: NSMenuItemValidation {
    /// "Bookmark This Page" and "Hide Sidebar" change: their titles say what they will do (also in
    /// Search Commands). "Bookmark This Page" and "Toggle Reader Mode" need a web page. The group
    /// items need a normal tab (and a group, to remove from). A hidden sidebar cannot fold.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleHidesSidebar(_:)) {
            menuItem.title = Preferences.hidesSidebar ? "Show Sidebar" : "Hide Sidebar"
            return true
        }
        if menuItem.action == #selector(toggleSidebarFold(_:)) {
            return !Preferences.hidesSidebar
        }
        if menuItem.action == #selector(addTabToNewGroup(_:)) {
            return store.selectedTab.map { !$0.isPinned } ?? false
        }
        if menuItem.action == #selector(removeTabFromGroup(_:)) {
            return store.selectedTab?.groupID != nil
        }
        if menuItem.action == #selector(toggleReader(_:)) {
            return store.selectedTab.flatMap(ReaderMode.menuItem) != nil
        }
        if menuItem.action == #selector(toggleAdsOnSite(_:)) {
            let site = AdBlocker.site(for: store.selectedTab?.url)
            menuItem.title = site.map(AdBlocker.shared.allowsAds) == true ? "Block Ads on This Site" : "Allow Ads on This Site"
            return Preferences.blocksAds && site != nil
        }
        guard menuItem.action == #selector(bookmarkPage(_:)) else { return true }
        guard let url = store.selectedTab?.url, ["http", "https"].contains(url.scheme ?? "") else {
            menuItem.title = "Bookmark This Page"
            return false
        }
        menuItem.title = BookmarkStore.shared.bookmark(for: url) == nil ? "Bookmark This Page" : "Remove Bookmark"
        return true
    }
}

extension BrowserWindowController: TabStoreDelegate {
    func tabStoreDidChangeTabs(_ store: TabStore) {
        sidebar.reloadTabs()
    }

    func tabStore(_ store: TabStore, didUpdate tab: Tab, change: Tab.Change) {
        switch change {
        case .title, .favicon, .themeColor, .sleepState, .url:
            sidebar.update(tab)
        case .loading, .progress, .navigationState, .hoveredLink:
            break
        }
        guard tab === store.selectedTab else { return }
        if change == .progress { return topBar.updateProgress(with: tab) }
        if change == .hoveredLink { return container.showStatus(tab.hoveredLink?.absoluteString) }
        if change == .url {
            addToBoskButton.update(for: tab.url)
            adBlockerButton.update(for: tab.url)
        }
        if change == .title || change == .url { window?.title = tab.displayTitle }
        if change == .sleepState { container.show(tab.webView) }
        // Keep the page picture until the woken page has loaded.
        if change == .loading, !tab.isLoading { container.hideSnapshot() }
        topBar.update(with: tab)
    }

    func tabStore(_ store: TabStore, didSelect tab: Tab?, previous: Tab?) {
        performanceSignposter.emitEvent("Tab switch")
        container.show(tab?.webView)
        // Clear the old tab's link, so the same link shows again when the user comes back.
        previous?.hoveredLink = nil
        container.showStatus(nil)
        addToBoskButton.update(for: tab?.url)
        adBlockerButton.update(for: tab?.url)
        extensionActions.reload()
        if rootView.isFindBarVisible { hideFindBar() }
        if let tab, tab.isAsleep, let data = tab.snapshotData {
            container.showSnapshot(NSImage(data: data))
        } else {
            container.hideSnapshot()
        }
        topBar.update(with: tab)
        // The title is hidden, but the Window menu lists a window only when it has a title.
        window?.title = tab?.displayTitle ?? "New Tab"
        sidebar.selectionChanged(from: previous, to: tab)
        if tab == nil { showCommandBar(target: .newTab) }
    }
}

/// The window's content: a solid background, the content card, and the
/// sidebar on top. Manual layout: no Auto Layout on this path.
@MainActor
private final class RootView: NSView {
    let sidebar: SidebarView
    let card = NSView()
    let topBar: TopBar
    let container: WebContainerView
    let findBar: FindBar
    /// A drag of the sidebar edge asks to fold (true) or open (false) the sidebar.
    var onDragFold: ((Bool) -> Void)?
    private let resizeHandle = SidebarResizeHandle()
    /// The open sidebar's width. The user changes it with a drag on the sidebar edge.
    private var openWidth = Preferences.sidebarWidth
    private(set) var isSidebarFolded = false
    /// Hidden (a setting): no sidebar and no strip. The card fills the window, as when folded.
    private var isSidebarHidden = Preferences.hidesSidebar
    private(set) var isFindBarVisible = false
    private var isAnimating = false

    init(sidebar: SidebarView, topBar: TopBar, container: WebContainerView, findBar: FindBar) {
        self.sidebar = sidebar
        self.topBar = topBar
        self.container = container
        self.findBar = findBar
        super.init(frame: .zero)
        wantsLayer = true

        card.wantsLayer = true
        card.layer?.cornerRadius = Defaults.contentCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.addSubview(container)
        card.addSubview(topBar)
        findBar.isHidden = true
        card.addSubview(findBar)
        addSubview(card)
        // Above the card: while the sidebar opens, it slides over the page.
        addSubview(sidebar)
        resizeHandle.onDrag = { [weak self] x in self?.dragSidebarEdge(to: x) }
        resizeHandle.onDragEnd = { [weak self] in
            guard let self, !self.isSidebarFolded else { return }
            Preferences.sidebarWidth = self.openWidth
        }
        addSubview(resizeHandle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = SidebarColors.background.cgColor
    }

    func setFindBarVisible(_ visible: Bool) {
        isFindBarVisible = visible
        findBar.isHidden = !visible
        layoutCard(sidebarWidth: sidebarWidth)
    }

    private var sidebarWidth: CGFloat {
        isSidebarHidden ? 0 : isSidebarFolded ? Defaults.stripWidth : openWidth
    }
    private var cardFillsWindow: Bool { isSidebarFolded || isSidebarHidden }
    /// When the card fills the window, its top bar is as tall as the open window's top:
    /// the space above the card plus the card's top bar. So the page starts at the same height.
    private static let fullTopBarHeight = Defaults.contentInset + Defaults.topBarHeight

    /// Folded, the strip starts under the top bar: the top bar goes under the window buttons.
    private var sidebarFrame: NSRect {
        let top = isSidebarFolded ? Self.fullTopBarHeight : 0
        return NSRect(x: 0, y: top, width: sidebarWidth, height: max(0, bounds.height - top))
    }

    /// `x` is the mouse position in this view. Narrow enough, the sidebar folds into the strip.
    private func dragSidebarEdge(to x: CGFloat) {
        guard !isAnimating else { return }
        let folds = x < Defaults.sidebarFoldDragWidth
        guard !folds else {
            if !isSidebarFolded { onDragFold?(true) }
            return
        }
        openWidth = min(max(x, Defaults.minimumSidebarWidth), Defaults.maximumSidebarWidth)
        if isSidebarFolded { onDragFold?(false) } else { needsLayout = true }
    }

    /// The web view changes size one time only, never on each animation frame:
    /// - Fold: the card takes its new size first, under the sidebar; then the sidebar shrinks
    ///   and shows the page.
    /// - Unfold: the sidebar grows over the page; then the card takes its new size.
    func setSidebarFolded(_ folded: Bool, animated: Bool) {
        isSidebarFolded = folded
        sidebar.setCompact(folded)
        guard animated, window != nil else {
            needsLayout = true
            return
        }
        isAnimating = true
        let target = sidebarFrame
        // Do the expensive work (new row layout, and for a fold the page resize, which
        // WebKit blocks until the page draws) in this frame. Start the animation in the next
        // frame, so no animation frame waits for that work.
        if folded { layoutCard(sidebarWidth: Defaults.stripWidth) }
        sidebar.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in self?.animateSidebar(to: target) }
    }

    func setSidebarHidden(_ hidden: Bool) {
        isSidebarHidden = hidden
        needsLayout = true
    }

    private func animateSidebar(to target: NSRect) {
        let signpost = performanceSignposter.beginInterval("Sidebar fold", id: performanceSignposter.makeSignpostID())
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Defaults.sidebarAnimationDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            context.allowsImplicitAnimation = true
            sidebar.animator().frame = target
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                performanceSignposter.endInterval("Sidebar fold", signpost)
                guard let self else { return }
                self.isAnimating = false
                self.needsLayout = true
            }
        })
    }

    override func layout() {
        super.layout()
        // The window lays out its title bar before this view.
        (window as? BoskWindow)?.centerWindowButtons()
        guard !isAnimating else { return }
        sidebar.isHidden = isSidebarHidden
        resizeHandle.isHidden = isSidebarHidden
        // Hidden, the sidebar keeps its frame: AppKit still lays out its rows, and a row
        // 0 pt wide gives null and NaN layer frames (a CALayer exception).
        if !isSidebarHidden { sidebar.frame = sidebarFrame }
        resizeHandle.frame = NSRect(x: sidebarWidth - 4, y: sidebarFrame.minY, width: 8, height: sidebarFrame.height)
        layoutCard(sidebarWidth: sidebarWidth)
    }

    /// Open: a rounded card next to the sidebar. Folded: the card fills the window, so the
    /// top bar goes under the window buttons, and the strip covers the card's left side
    /// under the top bar. Hidden: as folded, with no strip.
    private func layoutCard(sidebarWidth: CGFloat) {
        let inset = Defaults.contentInset
        card.frame = cardFillsWindow
            ? bounds
            : NSRect(x: sidebarWidth, y: inset,
                     width: max(0, bounds.width - sidebarWidth - inset),
                     height: max(0, bounds.height - inset * 2))
        card.layer?.cornerRadius = cardFillsWindow ? 0 : Defaults.contentCornerRadius
        let barHeight = cardFillsWindow ? Self.fullTopBarHeight : Defaults.topBarHeight
        // The window buttons can go past the strip: Back starts after them.
        // In full screen they are hidden.
        let isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
        let buttonsMaxX = isFullScreen ? 0 : window?.standardWindowButton(.zoomButton)?.frame.maxX ?? 0
        topBar.leadingInset = max(0, buttonsMaxX + 6 - card.frame.minX)
        let size = card.bounds.size
        // The card is not flipped: y = 0 is the bottom.
        topBar.frame = NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight)
        let contentX = cardFillsWindow ? sidebarWidth : 0
        let contentWidth = max(0, size.width - contentX)
        let findHeight: CGFloat = isFindBarVisible ? 36 : 0
        findBar.frame = NSRect(x: contentX, y: size.height - barHeight - findHeight, width: contentWidth, height: findHeight)
        container.frame = NSRect(x: contentX, y: 0, width: contentWidth, height: size.height - barHeight - findHeight)
    }
}

/// The sidebar edge: drag it to change the sidebar width.
@MainActor
private final class SidebarResizeHandle: NSView {
    /// The mouse x position in the superview.
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}
