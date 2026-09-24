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
        let groupID: UUID?
    }

    private(set) var pinnedTabs: [Tab] = []
    private(set) var tabs: [Tab] = []
    /// The tab groups of this window, in no special order; the tab list gives the order.
    private(set) var groups: [TabGroup] = []
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
            tab.groupID = saved.groupID
            tab.favicon = FaviconStore.shared.cachedIcon(for: saved.url)
            tab.store = self
            return tab
        }
        pinnedTabs = state.pinnedTabs.map(makeTab)
        tabs = state.tabs.map(makeTab)
        groups = state.groups ?? []
        let groupIDs = Set(groups.map(\.id))
        for tab in tabs where tab.groupID.map({ !groupIDs.contains($0) }) ?? false { tab.groupID = nil }
        syncPinnedTabs()
        let selected = allTabs.first { $0.id == state.selectedTabID } ?? tabs.last ?? pinnedTabs.first
        if let selected { select(selected) }
    }

    func windowState(frame: [Double]?, sidebarFolded: Bool) -> WindowState {
        func state(_ tab: Tab) -> TabState {
            tab.saveSessionState()
            return TabState(id: tab.id, url: tab.url, title: tab.title,
                            sessionState: tab.sessionState, pinnedEntryID: tab.pinnedEntryID, groupID: tab.groupID)
        }
        return WindowState(frame: frame, pinnedTabs: pinnedTabs.map(state), tabs: tabs.map(state),
                           selectedTabID: selectedTab?.id, sidebarFolded: sidebarFolded, groups: groups)
    }

    // MARK: Tabs

    /// - Parameter groupID: The new tab goes at the end of this group; nil puts it at the end of the list.
    @discardableResult
    func newTab(url: URL?, select: Bool = true, inGroup groupID: UUID? = nil) -> Tab {
        // A selected tab wakes and loads its URL. A background tab loads when first selected.
        let tab = Tab(url: url)
        tab.favicon = FaviconStore.shared.cachedIcon(for: url)
        insert(tab, after: groupID.flatMap { id in tabs.last { $0.groupID == id } }, select: select)
        return tab
    }

    /// - Parameter after: The new tab goes below this tab, in its group; nil puts it at the end.
    func insert(_ tab: Tab, after: Tab?, select: Bool) {
        tab.store = self
        if let after, let index = tabs.firstIndex(where: { $0 === after }) {
            place(tab, at: index + 1, preferredGroup: after.groupID)
        } else {
            place(tab, at: tabs.count)
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
            closedTabs.append(ClosedTab(url: tab.url, title: tab.title, sessionState: tab.sessionState,
                                        index: index, groupID: tab.groupID))
            if closedTabs.count > 20 { closedTabs.removeFirst() }
            tabs.remove(at: index)
            ExtensionManager.shared.didClose(tab)
            tab.close()
            tab.store = nil
            structureChanged()
        }
        if tab === selectedTab { selectAfterClosing(tab, at: allIndex) }
    }

    /// Closes the normal tabs other than `tab`. Pinned tabs stay. `tab` is selected first,
    /// so no tab that is about to close is selected (and woken) on the way.
    func closeOtherTabs(than tab: Tab) {
        select(tab)
        // One sidebar reload for all the tabs, not one for each tab.
        isClosingManyTabs = true
        for other in tabs where other !== tab { close(other) }
        isClosingManyTabs = false
        structureChanged()
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
        place(tab, at: closed.index, preferredGroup: closed.groupID)
        structureChanged()
        ExtensionManager.shared.didOpen(tab)
        select(tab)
    }

    /// - Parameter group: The tab's group after the move. The caller makes sure the group stays in one piece.
    func moveTab(_ tab: Tab, to index: Int, group: UUID?) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: min(index, tabs.count))
        tab.groupID = group
        structureChanged()
        ExtensionManager.shared.didMove(tab, from: pinnedTabs.count + from)
    }

    /// Moves a normal tab to `other`'s list and selects it there. The tab keeps
    /// its web view, so the page does not reload.
    /// - Parameters:
    ///   - index: The tab's place in `other`'s list; nil puts it at the end.
    ///   - group: A group of `other` next to `index` that the tab joins.
    func transfer(_ tab: Tab, to other: TabStore, at index: Int? = nil, group: UUID? = nil) {
        guard other !== self, let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let oldWindow = windowController
        let allIndex = pinnedTabs.count + from
        tabs.remove(at: from)
        structureChanged()
        // This window shows another tab first, so its container lets go of the web view.
        if tab === selectedTab { selectAfterClosing(tab, at: allIndex) }
        tab.store = other
        other.place(tab, at: index ?? other.tabs.count, preferredGroup: group)
        other.structureChanged()
        ExtensionManager.shared.didMove(tab, from: allIndex, in: oldWindow)
        other.select(tab)
    }

    // MARK: Pinning

    /// Pins a normal tab. This window keeps the same tab (and page); other windows get a sleeping copy.
    func pin(_ tab: Tab, at index: Int? = nil) {
        guard let from = tabs.firstIndex(where: { $0 === tab }), let url = tab.url else { return }
        tabs.remove(at: from)
        tab.groupID = nil
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
    /// - Parameter group: A group next to `index` that the tab joins.
    func unpin(_ tab: Tab, toIndex index: Int = 0, group: UUID? = nil) {
        guard let entryID = tab.pinnedEntryID else { return }
        pinnedTabs.removeAll { $0 === tab }
        tab.pinnedEntryID = nil
        place(tab, at: index, preferredGroup: group)
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
                place(tab, at: 0)
            } else {
                tab.close()
            }
        }
        structureChanged()
    }

    /// Puts a normal tab in at `index`. It joins a group only where the group stays in one piece.
    private func place(_ tab: Tab, at index: Int, preferredGroup: UUID? = nil) {
        let index = min(index, tabs.count)
        tab.groupID = TabGrouping.groupForInsertion(at: index, groupIDs: tabs.map(\.groupID), preferred: preferredGroup)
        tabs.insert(tab, at: index)
    }

    // MARK: Groups

    func group(_ id: UUID) -> TabGroup? { groups.first { $0.id == id } }

    /// Puts tabs in a new group with a color no other group has. The tabs keep their order and go
    /// where the first of them is; if that is inside a group, below that group, so it does not split.
    @discardableResult
    func addToNewGroup(_ selection: [Tab]) -> TabGroup? {
        let members = tabs.filter { tab in selection.contains { $0 === tab } }
        guard let first = members.first, let firstIndex = tabs.firstIndex(where: { $0 === first }) else { return nil }
        let oldIndexes = members.compactMap { tab in tabs.firstIndex { $0 === tab }.map { pinnedTabs.count + $0 } }
        tabs.removeAll { tab in members.contains { $0 === tab } }
        let destination = TabGrouping.blockInsertionIndex(at: firstIndex, groupIDs: tabs.map(\.groupID))
        // Only the colors of groups that still have tabs are in use.
        let usedColors = groups.filter { group in tabs.contains { $0.groupID == group.id } }.map(\.color)
        let group = TabGroup(color: .firstUnused(in: usedColors))
        groups.append(group)
        for tab in members { tab.groupID = group.id }
        tabs.insert(contentsOf: members, at: destination)
        structureChanged()
        for (tab, from) in zip(members, oldIndexes) { ExtensionManager.shared.didMove(tab, from: from) }
        return group
    }

    /// Moves a group with all its tabs, so they stay together.
    /// - Parameter index: The drop's insertion index in the list with the group still in it.
    func moveGroup(_ id: UUID, to index: Int) {
        guard let first = tabs.firstIndex(where: { $0.groupID == id }),
              let last = tabs.lastIndex(where: { $0.groupID == id }) else { return }
        let destination = TabGrouping.groupDestination(of: first...last, proposed: index, groupIDs: tabs.map(\.groupID))
        guard destination != first else { return }
        let members = Array(tabs[first...last])
        tabs.removeSubrange(first...last)
        tabs.insert(contentsOf: members, at: destination)
        structureChanged()
        for (offset, tab) in members.enumerated() {
            ExtensionManager.shared.didMove(tab, from: pinnedTabs.count + first + offset)
        }
    }

    /// Moves a tab to the end of a group.
    func add(_ tab: Tab, toGroup id: UUID) {
        guard tab.groupID != id, let from = tabs.firstIndex(where: { $0 === tab }),
              let last = tabs.lastIndex(where: { $0.groupID == id }) else { return }
        // The tab leaves its old place first, so a group below it moves up by one.
        moveTab(tab, to: from < last ? last : last + 1, group: id)
    }

    /// Moves a tab out of its group, to just below the group.
    func removeFromGroup(_ tab: Tab) {
        guard let id = tab.groupID, let last = tabs.lastIndex(where: { $0.groupID == id }) else { return }
        moveTab(tab, to: last, group: nil)
    }

    func updateGroup(_ id: UUID, title: String? = nil, color: TabGroupColor? = nil) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        if let title { groups[index].title = title }
        if let color { groups[index].color = color }
        structureChanged()
    }

    func toggleFold(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isFolded.toggle()
        structureChanged()
    }

    /// Removes the group. Its tabs stay where they are.
    func ungroup(_ id: UUID) {
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        structureChanged()
    }

    /// Closes all tabs of the group, and so the group.
    func closeGroup(_ id: UUID) {
        let members = tabs.filter { $0.groupID == id }
        guard let first = tabs.firstIndex(where: { $0.groupID == id }),
              let last = tabs.lastIndex(where: { $0.groupID == id }) else { return }
        // Select a tab outside the group first, so no tab that is about to close is selected (and woken).
        if let selectedTab, members.contains(where: { $0 === selectedTab }),
           let next = tabs[(last + 1)...].first ?? tabs[..<first].last ?? pinnedTabs.first {
            select(next)
        }
        isClosingManyTabs = true
        for tab in members { close(tab) }
        isClosingManyTabs = false
        structureChanged()
    }

    /// Moves the group and its tabs to the end of `other`'s list. The tabs keep their web views.
    func transferGroup(_ id: UUID, to other: TabStore) {
        guard other !== self, let group = group(id) else { return }
        let members = tabs.filter { $0.groupID == id }
        let selected = members.first { $0 === selectedTab } ?? members.first
        for tab in members { transfer(tab, to: other) }
        other.groups.append(group)
        for tab in members { tab.groupID = id }
        other.structureChanged()
        if let selected { other.select(selected) }
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
        // Not on title changes: some pages change their title each second ("(3) Inbox").
        // The title is saved with the next save, and at quit.
        if change == .url { SessionStore.shared.setNeedsSave() }
    }

    private var isClosingManyTabs = false

    private func structureChanged() {
        guard !isClosingManyTabs else { return }
        // A group with no tabs is gone.
        groups.removeAll { group in !tabs.contains { $0.groupID == group.id } }
        delegate?.tabStoreDidChangeTabs(self)
        SessionStore.shared.setNeedsSave()
    }
}
