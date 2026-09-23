import AppKit
import BoskCore

extension NSPasteboard.PasteboardType {
    /// A tab being dragged in the sidebar. The value is the tab's UUID.
    static let boskTab = NSPasteboard.PasteboardType("app.bosk.tab-id")
}

/// The left sidebar: space for the window buttons, the pinned grid, and the tab list.
/// Manual layout only; the tab list reuses row views.
@MainActor
final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let store: TabStore
    var onNewTab: (() -> Void)?
    var onToggleFold: (() -> Void)?

    let pinnedGrid = PinnedGridView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let foldButton = NSButton()
    /// Left of the fold button when Sparkle found an update. See Updater.
    private let updateButton = NSButton(title: "Update available", target: nil, action: nil)
    private let dismissUpdateButton = NSButton()
    /// Folded: a narrow strip of icons.
    private(set) var isCompact = false

    init(store: TabStore) {
        self.store = store
        super.init(frame: .zero)
        // Opaque, because the sidebar slides over the page while it opens.
        wantsLayer = true
        layer?.masksToBounds = true

        foldButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Fold Sidebar")
        foldButton.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        foldButton.isBordered = false
        foldButton.contentTintColor = .secondaryLabelColor
        foldButton.target = self
        foldButton.action = #selector(foldClicked)
        foldButton.toolTip = "Fold Sidebar (⌘S)"
        addSubview(foldButton)

        updateButton.bezelStyle = .accessoryBarAction
        updateButton.controlSize = .small
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        updateButton.toolTip = "Show the update"
        addSubview(updateButton)
        dismissUpdateButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss Update")
        dismissUpdateButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        dismissUpdateButton.isBordered = false
        dismissUpdateButton.contentTintColor = .secondaryLabelColor
        dismissUpdateButton.target = self
        dismissUpdateButton.action = #selector(dismissUpdateClicked)
        dismissUpdateButton.toolTip = "Remind me in 24 hours"
        addSubview(dismissUpdateButton)
        NotificationCenter.default.addObserver(forName: Updater.updateButtonDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }

        pinnedGrid.onSelect = { [weak self] tab in self?.store.select(tab) }
        pinnedGrid.onUnpin = { [weak self] tab in self?.store.unpin(tab) }
        pinnedGrid.onClose = { [weak self] tab in self?.store.close(tab) }
        pinnedGrid.onDrop = { [weak self] id, index in self?.dropOnGrid(tabID: id, at: index) }
        addSubview(pinnedGrid)

        let column = NSTableColumn(identifier: .init("tab"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.rowHeight = Defaults.tabRowHeight
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        tableView.registerForDraggedTypes([.boskTab])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .gap
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = SidebarColors.background.cgColor
    }

    func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        isCompact = compact
        pinnedGrid.columns = compact ? 1 : 3
        foldButton.image = NSImage(systemSymbolName: compact ? "sidebar.right" : "sidebar.left",
                                   accessibilityDescription: compact ? "Unfold Sidebar" : "Fold Sidebar")
        reloadTabs()
    }

    // MARK: Updates

    func reloadTabs() {
        pinnedGrid.reload(tabs: store.pinnedTabs, selected: store.selectedTab)
        tableView.reloadData()
        needsLayout = true
    }

    /// Updates one tab without reloading the list.
    func update(_ tab: Tab) {
        if tab.isPinned {
            pinnedGrid.update(tab, selected: store.selectedTab)
        } else if let row = store.tabs.firstIndex(where: { $0 === tab }),
                  let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? TabRowView {
            configure(rowView, row: row)
        }
    }

    func selectionChanged(from previous: Tab?, to tab: Tab?) {
        for changed in [previous, tab].compactMap({ $0 }) { update(changed) }
        if let tab, let row = store.tabs.firstIndex(where: { $0 === tab }) {
            tableView.scrollRowToVisible(row)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let padding: CGFloat = isCompact ? 8 : 10
        foldButton.frame = isCompact
            ? NSRect(x: bounds.midX - 14, y: Defaults.sidebarHeaderHeight - 6, width: 28, height: 28)
            : NSRect(x: bounds.maxX - 38, y: 8, width: 28, height: 28)
        layoutUpdateButton()
        var y = Defaults.sidebarHeaderHeight + (isCompact ? 28 : 0)
        let gridWidth = bounds.width - padding * 2
        let gridHeight = pinnedGrid.height(forWidth: gridWidth)
        pinnedGrid.frame = NSRect(x: padding, y: y, width: gridWidth, height: gridHeight)
        if gridHeight > 0 { y += gridHeight + 12 }
        scrollView.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
        tableView.tableColumns.first?.width = bounds.width
    }

    /// Not in the folded strip, and not when the sidebar is too narrow to keep it clear of the window buttons.
    private func layoutUpdateButton() {
        let dismissWidth: CGFloat = 16
        let width = updateButton.fittingSize.width
        let x = foldButton.frame.minX - dismissWidth - width
        let isVisible = Updater.showsUpdateButton && !isCompact && x >= Defaults.stripWidth
        updateButton.isHidden = !isVisible
        dismissUpdateButton.isHidden = !isVisible
        guard isVisible else { return }
        let height = updateButton.fittingSize.height
        updateButton.frame = NSRect(x: x, y: foldButton.frame.midY - height / 2, width: width, height: height)
        dismissUpdateButton.frame = NSRect(x: updateButton.frame.maxX, y: foldButton.frame.midY - 8,
                                           width: dismissWidth, height: 16)
    }

    // MARK: Table

    /// One row per normal tab, then the "New Tab" row.
    func numberOfRows(in tableView: NSTableView) -> Int { store.tabs.count + 1 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = tableView.makeView(withIdentifier: TabRowView.identifier, owner: nil) as? TabRowView
            ?? TabRowView()
        configure(rowView, row: row)
        return rowView
    }

    private func configure(_ rowView: TabRowView, row: Int) {
        guard row < store.tabs.count else {
            rowView.configure(title: "New Tab", icon: nil, isCurrent: false, isCompact: isCompact, isNewTabRow: true)
            return
        }
        let tab = store.tabs[row]
        rowView.onClose = { [weak self, weak tab] in
            guard let tab else { return }
            self?.store.close(tab)
        }
        rowView.configure(title: tab.displayTitle, icon: tab.favicon,
                          isCurrent: tab === store.selectedTab, isCompact: isCompact)
    }

    // MARK: Drag and drop

    private func tab(from info: NSDraggingInfo) -> Tab? {
        guard let id = info.draggingPasteboard.string(forType: .boskTab) else { return nil }
        return store.allTabs.first { $0.id.uuidString == id }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < store.tabs.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(store.tabs[row].id.uuidString, forType: .boskTab)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        // Show where to drop to pin, also when nothing is pinned yet.
        pinnedGrid.isShowingDropZone = true
        needsLayout = true
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pinnedGrid.isShowingDropZone = false
        needsLayout = true
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tab(from: info) != nil else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let tab = tab(from: info) else { return false }
        let row = min(row, store.tabs.count)
        if tab.isPinned {
            store.unpin(tab, toIndex: row)
        } else if let from = store.tabs.firstIndex(where: { $0 === tab }) {
            store.moveTab(tab, to: TabOrdering.moveDestination(from: from, proposedRow: row))
        }
        return true
    }

    private func dropOnGrid(tabID: String, at index: Int) {
        guard let tab = store.allTabs.first(where: { $0.id.uuidString == tabID }) else { return }
        if let entryID = tab.pinnedEntryID,
           let from = PinnedStore.shared.entries.firstIndex(where: { $0.id == entryID }) {
            PinnedStore.shared.move(entryID, to: TabOrdering.moveDestination(from: from, proposedRow: index))
        } else {
            store.pin(tab, at: index)
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        if row < store.tabs.count { store.select(store.tabs[row]) } else { onNewTab?() }
    }

    @objc private func foldClicked() { onToggleFold?() }
    @objc private func updateClicked() { Updater.checkForUpdates() }
    @objc private func dismissUpdateClicked() { Updater.dismissUpdateButton() }
}

extension SidebarView: NSMenuDelegate {
    /// The right-click menu for the clicked tab row.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < store.tabs.count else { return }
        let tab = store.tabs[row]
        menu.addItem(ClosureMenuItem("Pin Tab") { [weak self] in self?.store.pin(tab) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Tab") { [weak self] in self?.store.close(tab) })
    }
}
