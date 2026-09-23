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
    private let sidebar: SidebarView
    private let rootView: RootView
    private lazy var commandBar = CommandBarPanel()

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
        window.minSize = Defaults.minimumWindowSize
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        super.init(window: window)
        window.delegate = self

        topBar.onAddressClick = { [weak self] in self?.openLocation(nil) }
        sidebar.onNewTab = { [weak self] in self?.showCommandBar(target: .newTab) }
        sidebar.onToggleFold = { [weak self] in self?.toggleSidebar(nil) }
        store.delegate = self
        store.window = window
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        extensionActions.currentTab = { [weak self] in self?.store.selectedTab }
        topBar.setAccessoryViews([addToBoskButton, extensionActions, DownloadsButton()])
        ExtensionManager.shared.addObserver(self) { [weak self] in self?.extensionActions.reload() }
        NotificationCenter.default.addObserver(forName: PageZoom.didChangeDefault, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                for tab in self?.store.allTabs ?? [] where tab.zoomOverride == nil {
                    tab.webView?.pageZoom = PageZoom.defaultZoom
                }
            }
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

    func showCommandBar(target: CommandBarPanel.Target) {
        guard let window else { return }
        let text = target == .currentTab ? (store.selectedTab?.url?.absoluteString ?? "") : ""
        commandBar.present(over: window, text: text, target: target, provider: { text in
            let openTabs = (NSApp.delegate as? AppDelegate)?.allTabs.map {
                SuggestionRanker.OpenTab(id: $0.id, url: $0.url, title: $0.title)
            } ?? []
            let history = await HistoryStore.shared.candidates(for: text)
            return SuggestionRanker.suggestions(for: text, openTabs: openTabs, history: history,
                                                now: Date(), searchURL: Defaults.searchURL)
        }, onChoose: { [weak self] choice, target in
            self?.choose(choice, target: target)
        })
    }

    private func choose(_ choice: SuggestionRanker.Suggestion, target: CommandBarPanel.Target) {
        switch choice {
        case .typed(let url), .history(_, let url):
            if target == .currentTab, let tab = store.selectedTab {
                tab.load(url)
            } else {
                store.newTab(url: url)
            }
            focusWebView()
        case .openTab(let id, _, _):
            (NSApp.delegate as? AppDelegate)?.showTab(id: id)
        }
    }

    private func focusWebView() {
        if let webView = store.selectedTab?.webView { window?.makeFirstResponder(webView) }
    }

    // MARK: Sidebar

    // MARK: Extensions

    func extensionActionsChanged() {
        extensionActions.reload()
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
    @objc func closeTab(_ sender: Any?) {
        if let tab = store.selectedTab { store.close(tab) } else { window?.performClose(sender) }
    }
    @objc func reopenClosedTab(_ sender: Any?) { store.reopenClosedTab() }
    @objc func browserBack(_ sender: Any?) { store.selectedTab?.webView?.goBack() }
    @objc func browserForward(_ sender: Any?) { store.selectedTab?.webView?.goForward() }
    @objc func browserReload(_ sender: Any?) { store.selectedTab?.webView?.reload() }
    @objc func browserStop(_ sender: Any?) { store.selectedTab?.webView?.stopLoading() }
    @objc func selectNextTab(_ sender: Any?) { store.selectNeighbor(offset: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { store.selectNeighbor(offset: -1) }
    /// Cmd+1…8 select that tab; Cmd+9 selects the last tab (as in other browsers).
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        if sender.tag == 9 { store.select(at: store.allTabs.count - 1) } else { store.select(at: sender.tag - 1) }
    }
    @objc func toggleSidebar(_ sender: Any?) {
        setSidebarFolded(!rootView.isSidebarFolded, animated: true)
    }
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

    @objc func togglePinTab(_ sender: Any?) {
        guard let tab = store.selectedTab else { return }
        if tab.isPinned { store.unpin(tab) } else { store.pin(tab) }
    }

    func windowDidMove(_ notification: Notification) { SessionStore.shared.setNeedsSave() }
    func windowDidBecomeKey(_ notification: Notification) { ExtensionManager.shared.controller.didFocusWindow(self) }
    func windowDidEndLiveResize(_ notification: Notification) { SessionStore.shared.setNeedsSave() }

    func windowWillClose(_ notification: Notification) {
        for tab in store.allTabs {
            ExtensionManager.shared.didClose(tab, windowIsClosing: true)
            tab.close()
        }
        ExtensionManager.shared.controller.didCloseWindow(self)
        (NSApp.delegate as? AppDelegate)?.windowControllerDidClose(self)
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
        case .loading, .navigationState:
            break
        }
        guard tab === store.selectedTab else { return }
        if change == .url { addToBoskButton.update(for: tab.url) }
        if change == .sleepState { container.show(tab.webView) }
        // Keep the page picture until the woken page has loaded.
        if change == .loading, !tab.isLoading { container.hideSnapshot() }
        topBar.update(with: tab)
    }

    func tabStore(_ store: TabStore, didSelect tab: Tab?, previous: Tab?) {
        performanceSignposter.emitEvent("Tab switch")
        container.show(tab?.webView)
        addToBoskButton.update(for: tab?.url)
        extensionActions.reload()
        if rootView.isFindBarVisible { hideFindBar() }
        if let tab, tab.isAsleep, let data = tab.snapshotData {
            container.showSnapshot(NSImage(data: data))
        } else {
            container.hideSnapshot()
        }
        topBar.update(with: tab)
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
    private(set) var isSidebarFolded = false
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

    private var sidebarWidth: CGFloat { isSidebarFolded ? Defaults.stripWidth : Defaults.sidebarWidth }

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
        let target = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        // Do the expensive work (new row layout, and for a fold the page resize, which
        // WebKit blocks until the page draws) in this frame. Start the animation in the next
        // frame, so no animation frame waits for that work.
        if folded { layoutCard(sidebarWidth: Defaults.stripWidth) }
        sidebar.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in self?.animateSidebar(to: target) }
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
        guard !isAnimating else { return }
        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        layoutCard(sidebarWidth: sidebarWidth)
    }

    private func layoutCard(sidebarWidth: CGFloat) {
        let inset = Defaults.contentInset
        card.frame = NSRect(x: sidebarWidth, y: inset,
                            width: max(0, bounds.width - sidebarWidth - inset),
                            height: max(0, bounds.height - inset * 2))
        let barHeight = Defaults.topBarHeight
        let size = card.bounds.size
        // The card is not flipped: y = 0 is the bottom.
        topBar.frame = NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight)
        let findHeight: CGFloat = isFindBarVisible ? 36 : 0
        findBar.frame = NSRect(x: 0, y: size.height - barHeight - findHeight, width: size.width, height: findHeight)
        container.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - barHeight - findHeight)
    }
}
