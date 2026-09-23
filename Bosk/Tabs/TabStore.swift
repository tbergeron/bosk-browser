import AppKit
import BoskCore

@MainActor
protocol TabStoreDelegate: AnyObject {
    /// Tabs were added, removed, moved, pinned or unpinned.
    func tabStoreDidChangeTabs(_ store: TabStore)
    /// One tab changed. Update only that tab's row.
    func tabStore(_ store: TabStore, didUpdate tab: Tab, change: Tab.Change)
    func tabStore(_ store: TabStore, didSelect tab: Tab?, previous: Tab?)
}

/// The tabs of one window. Every change to a tab goes through here.
@MainActor
final class TabStore {
    private struct ClosedTab {
        let url: URL?
        let title: String
        let sessionState: Data?
        let index: Int
    }

    private(set) var pinnedTabs: [Tab] = []
    private(set) var tabs: [Tab] = []
    private(set) var selectedTab: Tab?
    private var closedTabs: [ClosedTab] = []
    weak var delegate: TabStoreDelegate?
    /// The window that shows these tabs. Page dialogs open as sheets on it.
    weak var window: NSWindow?
    var windowController: BrowserWindowController? { window?.windowController as? BrowserWindowController }

    var allTabs: [Tab] { pinnedTabs + tabs }

    init() {
        PinnedStore.shared.addObserver(self) { [weak self] in self?.syncPinnedTabs() }
    }

    isolated deinit {
        PinnedStore.shared.removeObserver(self)
    }

    // MARK: Session

    /// Rebuilds the tabs from a saved window. All tabs start asleep; only the selected tab loads.
    func restore(_ state: WindowState) {
        func makeTab(_ saved: TabState) -> Tab {
            let tab = Tab(id: saved.id, url: saved.url, title: saved.title, sessionState: saved.sessionState)
            tab.pinnedEntryID = saved.pinnedEntryID
            tab.favicon = FaviconStore.shared.cachedIcon(for: saved.url)
            tab.store = self
            return tab
        }
        pinnedTabs = state.pinnedTabs.map(makeTab)
        tabs = state.tabs.map(makeTab)
        syncPinnedTabs()
        let selected = allTabs.first { $0.id == state.selectedTabID } ?? tabs.last ?? pinnedTabs.first
        if let selected { select(selected) }
    }

    func windowState(frame: [Double]?, sidebarFolded: Bool) -> WindowState {
        func state(_ tab: Tab) -> TabState {
            tab.saveSessionState()
            return TabState(id: tab.id, url: tab.url, title: tab.title,
                            sessionState: tab.sessionState, pinnedEntryID: tab.pinnedEntryID)
        }
        return WindowState(frame: frame, pinnedTabs: pinnedTabs.map(state), tabs: tabs.map(state),
                           selectedTabID: selectedTab?.id, sidebarFolded: sidebarFolded)
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL?, select: Bool = true) -> Tab {
        // A selected tab wakes and loads its URL. A background tab loads when first selected.
        let tab = Tab(url: url)
        tab.favicon = FaviconStore.shared.cachedIcon(for: url)
        insert(tab, after: nil, select: select)
        return tab
    }

    /// - Parameter after: The new tab goes below this tab; nil puts it at the end.
    func insert(_ tab: Tab, after: Tab?, select: Bool) {
        tab.store = self
        if let after, let index = tabs.firstIndex(where: { $0 === after }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        structureChanged()
        ExtensionManager.shared.didOpen(tab)
        if select { self.select(tab) }
    }

    func select(_ tab: Tab) {
        guard tab !== selectedTab else { return }
        let previous = selectedTab
        let now = Date()
        previous?.lastActive = now
        previous?.captureSnapshot()
        tab.lastActive = now
        selectedTab = tab
        if tab.isAsleep {
            // Show the saved picture in this frame; make the web view (slow) in the next one.
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let tab, self?.selectedTab === tab else { return }
                tab.wake()
            }
        }
        delegate?.tabStore(self, didSelect: tab, previous: previous)
        ExtensionManager.shared.didActivate(tab, previous: previous)
        SessionStore.shared.setNeedsSave()
    }

    func select(at index: Int) {
        let all = allTabs
        guard all.indices.contains(index) else { return }
        select(all[index])
    }

    func selectNeighbor(offset: Int) {
        let all = allTabs
        guard !all.isEmpty else { return }
        let current = selectedTab.flatMap { tab in all.firstIndex { $0 === tab } } ?? 0
        select(all[(current + offset + all.count) % all.count])
    }

    /// Closing a pinned tab does not remove the pin: the tab goes back to its pinned
    /// page and sleeps. Unpin removes it.
    func close(_ tab: Tab) {
        let all = allTabs
        guard let allIndex = all.firstIndex(where: { $0 === tab }) else { return }
        if tab.isPinned, let entryID = tab.pinnedEntryID, let entry = PinnedStore.shared.entry(entryID) {
            tab.reset(to: entry.url, title: entry.title)
        } else if let index = tabs.firstIndex(where: { $0 === tab }) {
            tab.saveSessionState()
            closedTabs.append(ClosedTab(url: tab.url, title: tab.title, sessionState: tab.sessionState, index: index))
            if closedTabs.count > 20 { closedTabs.removeFirst() }
            tabs.remove(at: index)
            ExtensionManager.shared.didClose(tab)
            tab.close()
            tab.store = nil
            structureChanged()
        }
        if tab === selectedTab { selectAfterClosing(tab, at: allIndex) }
    }

    private func selectAfterClosing(_ closed: Tab, at index: Int) {
        selectedTab = nil
        if let opener = closed.opener, allTabs.contains(where: { $0 === opener }) {
            return select(opener)
        }
        // Prefer a normal tab: the tab below takes its place, like closing a line in a list.
        let candidates = tabs.isEmpty ? pinnedTabs.filter { $0 !== closed } : tabs
        let normalIndex = max(0, index - pinnedTabs.count)
        if let next = candidates.isEmpty ? nil : candidates[min(normalIndex, candidates.count - 1)] {
            select(next)
        } else {
            delegate?.tabStore(self, didSelect: nil, previous: closed)
        }
    }

    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let tab = Tab(url: closed.url, title: closed.title, sessionState: closed.sessionState)
        tab.favicon = FaviconStore.shared.cachedIcon(for: closed.url)
        tab.store = self
        tabs.insert(tab, at: min(closed.index, tabs.count))
        structureChanged()
        ExtensionManager.shared.didOpen(tab)
        select(tab)
    }

    func moveTab(_ tab: Tab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: min(index, tabs.count))
        structureChanged()
        ExtensionManager.shared.didMove(tab, from: pinnedTabs.count + from)
    }

    // MARK: Pinning

    /// Pins a normal tab. This window keeps the same tab (and page); other windows get a sleeping copy.
    func pin(_ tab: Tab, at index: Int? = nil) {
        guard let from = tabs.firstIndex(where: { $0 === tab }), let url = tab.url else { return }
        tabs.remove(at: from)
        let entry = PinnedStore.shared.pin(url: url, title: tab.title, at: index)
        tab.pinnedEntryID = entry.id
        // `pin` above already called syncPinnedTabs, which made a new tab for this entry.
        // Put this tab in its place, so the page does not reload.
        if let copy = pinnedTabs.firstIndex(where: { $0.pinnedEntryID == entry.id }) {
            pinnedTabs[copy].close()
            pinnedTabs[copy] = tab
        }
        structureChanged()
    }

    /// Unpins everywhere. This window keeps the page as a normal tab at the top of the list.
    func unpin(_ tab: Tab, toIndex index: Int = 0) {
        guard let entryID = tab.pinnedEntryID else { return }
        pinnedTabs.removeAll { $0 === tab }
        tab.pinnedEntryID = nil
        tabs.insert(tab, at: min(index, tabs.count))
        PinnedStore.shared.unpin(entryID)
        structureChanged()
    }

    /// Makes `pinnedTabs` match `PinnedStore` (order, new pins, removed pins).
    func syncPinnedTabs() {
        var existing = Dictionary(pinnedTabs.compactMap { tab in tab.pinnedEntryID.map { ($0, tab) } },
                                  uniquingKeysWith: { first, _ in first })
        let synced: [Tab] = PinnedStore.shared.entries.map { entry in
            if let tab = existing.removeValue(forKey: entry.id) { return tab }
            let tab = Tab(url: entry.url, title: entry.title)
            tab.pinnedEntryID = entry.id
            tab.favicon = FaviconStore.shared.cachedIcon(for: entry.url)
            tab.store = self
            return tab
        }
        let removed = existing.values
        pinnedTabs = synced
        for tab in removed where tab.pinnedEntryID != nil {
            if tab === selectedTab {
                // Another window unpinned it: keep the page here as a normal tab.
                tab.pinnedEntryID = nil
                tabs.insert(tab, at: 0)
            } else {
                tab.close()
            }
        }
        structureChanged()
    }

    // MARK: Changes

    func tabDidChange(_ tab: Tab, _ change: Tab.Change) {
        delegate?.tabStore(self, didUpdate: tab, change: change)
        switch change {
        case .title: ExtensionManager.shared.didChange(.title, for: tab)
        case .url: ExtensionManager.shared.didChange(.URL, for: tab)
        case .loading: ExtensionManager.shared.didChange(.loading, for: tab)
        default: break
        }
        if change == .url || change == .title { SessionStore.shared.setNeedsSave() }
    }

    private func structureChanged() {
        delegate?.tabStoreDidChangeTabs(self)
        SessionStore.shared.setNeedsSave()
    }
}
