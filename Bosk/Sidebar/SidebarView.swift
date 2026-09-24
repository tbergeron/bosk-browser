import AppKit
import BoskCore

extension NSPasteboard.PasteboardType {
    /// A tab being dragged in the sidebar. The value is the tab's UUID.
    static let boskTab = NSPasteboard.PasteboardType("app.bosk.tab-id")
    /// A tab group header being dragged in the tab list. The value is the group's UUID.
    static let boskTabGroup = NSPasteboard.PasteboardType("app.bosk.tab-group-id")
}

/// The left sidebar: space for the window buttons, the pinned grid, and the tab list.
/// Manual layout only; the tab list reuses row views.
@MainActor
final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let store: TabStore
    var onNewTab: (() -> Void)?
    var onNewTabInGroup: ((UUID) -> Void)?
    var onToggleFold: (() -> Void)?

    let pinnedGrid = PinnedGridView()
    private let scrollView = NSScrollView()
    private let tableView = SidebarTableView()
    private let foldButton = SidebarHoverButton()
    /// Folded: a narrow strip of icons.
    private(set) var isCompact = false
    /// The normal tab in a drag from the tab list.
    private var draggedTab: Tab?
    /// Tabs added to the selection with Cmd+click. With any, the current tab is in the selection too.
    private var multiSelection: Set<UUID> = []
    /// The table rows: group headers, the visible tabs, and "New Tab". Made in `reloadTabs`.
    private var rows: [SidebarItem] = [.newTab]
    private let groupPopover = NSPopover()

    init(store: TabStore) {
        self.store = store
        super.init(frame: .zero)
        // Opaque, because the sidebar slides over the page while it opens.
        wantsLayer = true
        layer?.masksToBounds = true

        foldButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Fold Sidebar")
        foldButton.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        foldButton.isBordered = false
        foldButton.refusesFirstResponder = true
        foldButton.contentTintColor = .secondaryLabelColor
        foldButton.target = self
        foldButton.action = #selector(foldClicked)
        foldButton.toolTip = "Fold Sidebar (⌘S)"
        addSubview(foldButton)


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
        // "Close Other Tabs" is disabled when there is no other tab.
        tableView.menu?.autoenablesItems = false
        tableView.registerForDraggedTypes([.boskTab, .boskTabGroup])
        tableView.canDragRow = { [weak self] row in
            guard let self, rows.indices.contains(row) else { return false }
            return rows[row] != .newTab
        }
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .gap
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)
        groupPopover.behavior = .transient
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
        SidebarTooltip.hide()
        pinnedGrid.isCompact = compact
        foldButton.image = NSImage(systemSymbolName: compact ? "sidebar.right" : "sidebar.left",
                                   accessibilityDescription: compact ? "Unfold Sidebar" : "Fold Sidebar")
        reloadTabs()
    }

    // MARK: Updates

    func reloadTabs() {
        // The rows are made again, so the hovered row may be gone and get no "exited" event.
        SidebarTooltip.hide()
        pinnedGrid.reload(tabs: store.pinnedTabs, selected: store.selectedTab)
        rows = TabGrouping.items(groupIDs: store.tabs.map(\.groupID),
                                 folded: Set(store.groups.filter(\.isFolded).map(\.id)),
                                 selectedIndex: store.selectedTab.flatMap { tab in store.tabs.firstIndex { $0 === tab } })
        tableView.reloadData()
        needsLayout = true
    }

    /// Updates one tab without reloading the list.
    func update(_ tab: Tab) {
        if tab.isPinned {
            pinnedGrid.update(tab, selected: store.selectedTab)
        } else if let row = row(of: tab),
                  let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? TabRowView {
            configure(rowView, row: row)
        }
    }

    func selectionChanged(from previous: Tab?, to tab: Tab?) {
        // A folded group shows only the current tab, so its rows change with the selection.
        if [previous, tab].contains(where: { $0?.groupID.flatMap(store.group)?.isFolded == true }) {
            reloadTabs()
        } else {
            for changed in [previous, tab].compactMap({ $0 }) { update(changed) }
        }
        if let tab, let row = row(of: tab) {
            tableView.scrollRowToVisible(row)
        }
    }

    private func row(of tab: Tab) -> Int? {
        store.tabs.firstIndex { $0 === tab }.flatMap { rows.firstIndex(of: .tab($0)) }
    }

    /// The tab of a tab row. Nil for a header, "New Tab", or a row from before a change.
    private func tab(atRow row: Int) -> Tab? {
        guard rows.indices.contains(row), case .tab(let index) = rows[row], store.tabs.indices.contains(index) else { return nil }
        return store.tabs[index]
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let padding: CGFloat = isCompact ? 8 : 10
        // The folded strip starts under the top bar, so its fold button is at the top.
        // In the strip, the fold button and the pinned tiles are in slots of the tile height, with the
        // tile spacing between them. The rows below (groups, tabs, "New Tab") are smaller (TabRowView).
        let slot = pinnedGrid.tileHeight
        let gap = pinnedGrid.spacing
        // In the strip, the button's hover box is as wide as a tab's box (TabRowView), with the same
        // space above it (to the top bar) as below it (to the first item).
        foldButton.frame = isCompact
            ? NSRect(x: 8, y: gap, width: bounds.width - 16, height: slot - gap)
            : NSRect(x: bounds.maxX - 38, y: (Defaults.sidebarHeaderHeight - 28) / 2, width: 28, height: 28)
        var y = isCompact ? slot + gap : Defaults.sidebarHeaderHeight
        let gridWidth = bounds.width - padding * 2
        let gridHeight = pinnedGrid.height(forWidth: gridWidth)
        pinnedGrid.frame = NSRect(x: padding, y: y, width: gridWidth, height: gridHeight)
        if gridHeight > 0 { y += gridHeight + (isCompact ? gap : 12) }
        // A strip row has 2 pt above its box (TabRowView), so the first box is `gap` below the tiles.
        if isCompact { y -= 2 }
        scrollView.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
        tableView.tableColumns.first?.width = bounds.width
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .group(let id) = rows[row], let group = store.group(id) {
            let rowView = tableView.makeView(withIdentifier: TabGroupRowView.identifier, owner: nil) as? TabGroupRowView
                ?? TabGroupRowView()
            let nextIsTab = if row + 1 < rows.count, case .tab = rows[row + 1] { true } else { false }
            rowView.configure(title: group.title, tabCount: store.tabs.count { $0.groupID == id },
                              color: SidebarColors.group(group.color), isFolded: group.isFolded,
                              isCompact: isCompact, endsHere: !nextIsTab || tab(atRow: row + 1)?.groupID != id)
            return rowView
        }
        let rowView = tableView.makeView(withIdentifier: TabRowView.identifier, owner: nil) as? TabRowView
            ?? TabRowView()
        configure(rowView, row: row)
        return rowView
    }

    private func configure(_ rowView: TabRowView, row: Int) {
        guard let tab = tab(atRow: row) else {
            rowView.configure(title: "New Tab", icon: nil, isCurrent: false, isCompact: isCompact, isNewTabRow: true)
            return
        }
        rowView.onClose = { [weak self, weak tab] in
            guard let tab else { return }
            self?.store.close(tab)
        }
        let group = tab.groupID.flatMap(store.group)
        rowView.configure(title: tab.displayTitle, icon: tab.favicon,
                          isCurrent: tab === store.selectedTab, isCompact: isCompact,
                          groupColor: group.map { SidebarColors.group($0.color) },
                          isLastInGroup: group != nil && self.tab(atRow: row + 1)?.groupID != group?.id,
                          isMultiSelected: multiSelection.contains(tab.id))
    }

    // MARK: Drag and drop

    private func tab(from info: NSDraggingInfo) -> Tab? {
        guard let id = info.draggingPasteboard.string(forType: .boskTab) else { return nil }
        return store.allTabs.first { $0.id.uuidString == id }
    }

    /// A normal tab dragged from the tab list of another window.
    private func tabFromOtherWindow(_ info: NSDraggingInfo) -> Tab? {
        guard let id = info.draggingPasteboard.string(forType: .boskTab),
              let tab = (NSApp.delegate as? AppDelegate)?.allTabs.first(where: { $0.id.uuidString == id }),
              tab.store !== store, !tab.isPinned else { return nil }
        return tab
    }

    /// A group header dragged in this window's tab list.
    private func group(from info: NSDraggingInfo) -> UUID? {
        guard let text = info.draggingPasteboard.string(forType: .boskTabGroup),
              let id = UUID(uuidString: text), store.group(id) != nil else { return nil }
        return id
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        if rows.indices.contains(row), case .group(let id) = rows[row] {
            item.setString(id.uuidString, forType: .boskTabGroup)
            return item
        }
        guard let tab = tab(atRow: row) else { return nil }
        item.setString(tab.id.uuidString, forType: .boskTab)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        // The row leaves with the pointer; its title must not stay behind.
        SidebarTooltip.hide()
        // The table makes its drag image from cell views, and this list has none (it draws whole
        // rows), so the drag showed nothing. Use a picture of the row.
        if let row = rowIndexes.first, let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) {
            let image = dragImage(of: rowView)
            let frame = tableView.rect(ofRow: row)
            session.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self],
                                           searchOptions: [:]) { item, _, _ in
                item.setDraggingFrame(frame, contents: image)
            }
        }
        draggedTab = rowIndexes.first.flatMap { tab(atRow: $0) }
        guard draggedTab != nil else { return }
        // A tab dropped outside the window becomes a window there: do not slide it back.
        session.animatesToStartingPositionsOnCancelOrFail = false
        // Show where to drop to pin, also when nothing is pinned yet.
        pinnedGrid.isShowingDropZone = true
        needsLayout = true
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pinnedGrid.isShowingDropZone = false
        needsLayout = true
        let tab = draggedTab
        draggedTab = nil
        // Dropped outside every Bosk window: the tab gets its own window.
        guard operation.isEmpty, let tab, store.tabs.count > 1,
              !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(screenPoint) }) else { return }
        (NSApp.delegate as? AppDelegate)?.moveToNewWindow(tab, topLeft: screenPoint)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if let dragged = group(from: info) {
            // A group goes between groups and loose tabs. Inside another group, show the line
            // above that group's header, as the group cannot go there.
            var target = row
            if rows.indices.contains(row), case .tab(let index) = rows[row],
               let other = store.tabs[index].groupID, other != dragged,
               let header = rows.firstIndex(of: .group(other)) {
                target = header
            }
            tableView.setDropRow(target, dropOperation: .above)
            return .move
        }
        // Pinned tabs are in every window already, so only normal tabs come from another window.
        guard tab(from: info) != nil || tabFromOtherWindow(info) != nil else { return [] }
        // On a group header, the tab joins the group. On any other row, it goes above the row.
        let isHeader = if rows.indices.contains(row), case .group = rows[row] { true } else { false }
        if dropOperation == .on, !isHeader { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let target = TabGrouping.dropTarget(items: rows, groupIDs: store.tabs.map(\.groupID),
                                            row: row, on: dropOperation == .on)
        if let group = group(from: info) {
            store.moveGroup(group, to: target.index)
            return true
        }
        if let tab = tabFromOtherWindow(info) {
            tab.store?.transfer(tab, to: store, at: target.index, group: target.groupID)
            return true
        }
        guard let tab = tab(from: info) else { return false }
        if tab.isPinned {
            store.unpin(tab, toIndex: target.index, group: target.groupID)
        } else if let from = store.tabs.firstIndex(where: { $0 === tab }) {
            store.moveTab(tab, to: TabOrdering.moveDestination(from: from, proposedRow: target.index),
                          group: target.groupID)
        }
        return true
    }

    /// A picture of the row on the sidebar color, so it can be read over the page. It is made at
    /// once from the row's layers: the rows draw with layers, which `cacheDisplay` leaves out, and
    /// the table hides the row while it is dragged.
    private func dragImage(of rowView: NSView) -> NSImage {
        let size = rowView.bounds.size
        let scale = window?.backingScaleFactor ?? 2
        guard let layer = rowView.layer,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage(size: size) }
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.setFillColor(rowView.resolved(SidebarColors.background.withAlphaComponent(0.9)))
        cg.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 0),
                          cornerWidth: 8, cornerHeight: 8, transform: nil))
        cg.fillPath()
        // The table has hidden the row already; show it only for the picture.
        let wasHidden = rowView.isHidden
        rowView.isHidden = false
        // Rows are flipped (y = 0 is the top); the bitmap is not.
        if rowView.isFlipped {
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
        }
        layer.render(in: cg)
        rowView.isHidden = wasHidden
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
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
        guard rows.indices.contains(row) else { return }
        if case .tab = rows[row], let tab = tab(atRow: row), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            return toggleMultiSelection(tab)
        }
        clearMultiSelection()
        switch rows[row] {
        case .tab: if let tab = tab(atRow: row) { store.select(tab) }
        case .group(let id): store.toggleFold(id)
        case .newTab: onNewTab?()
        }
    }

    // MARK: Selection of many tabs

    /// Cmd+click adds a tab to the selection or takes it out. The current tab is always in it.
    private func toggleMultiSelection(_ tab: Tab) {
        guard tab !== store.selectedTab else { return }
        if multiSelection.remove(tab.id) == nil { multiSelection.insert(tab.id) }
        reloadTabs()
    }

    private func clearMultiSelection() {
        guard !multiSelection.isEmpty else { return }
        multiSelection = []
        reloadTabs()
    }

    /// The selected normal tabs in list order: the Cmd+clicked tabs and the current tab.
    /// Without a Cmd+click, only the current tab.
    var selectedTabs: [Tab] {
        store.tabs.filter { $0 === store.selectedTab || multiSelection.contains($0.id) }
    }

    // MARK: Groups

    /// Puts the tabs in a new group, and opens the group panel to name it.
    func addToNewGroup(_ tabs: [Tab]) {
        clearMultiSelection()
        guard let group = store.addToNewGroup(tabs) else { return }
        showGroupEditor(group.id)
    }

    /// Opens the group panel below the group header.
    func showGroupEditor(_ id: UUID) {
        guard let row = rows.firstIndex(of: .group(id)) else { return }
        SidebarTooltip.hide()
        let actions = TabGroupEditor.Actions(
            newTab: { [weak self] in self?.onNewTabInGroup?(id) },
            // With every tab of the window in the group, the new window would be the same as this one.
            moveToNewWindow: store.tabs.allSatisfy({ $0.groupID == id }) ? nil : { [weak self] in
                guard let self else { return }
                (NSApp.delegate as? AppDelegate)?.moveGroupToNewWindow(id, from: store)
            },
            close: { [weak self] in self?.store.closeGroup(id) },
            ungroup: { [weak self] in self?.store.ungroup(id) },
            dismiss: { [weak self] in self?.groupPopover.close() })
        groupPopover.contentViewController = TabGroupEditor(store: store, groupID: id, actions: actions)
        // Relative to the table, not the row view: each name change reloads the rows.
        tableView.scrollRowToVisible(row)
        groupPopover.show(relativeTo: tableView.rect(ofRow: row), of: tableView, preferredEdge: .maxY)
    }

    /// The window's groups, in list order, for "Add Tab to Group".
    private var groupsInOrder: [TabGroup] {
        rows.compactMap { item in if case .group(let id) = item { store.group(id) } else { nil } }
    }

    private func menuTitle(of group: TabGroup) -> String {
        guard group.title.isEmpty else { return group.title }
        let count = store.tabs.count { $0.groupID == group.id }
        return count == 1 ? "1 Tab" : "\(count) Tabs"
    }

    /// A dot in the group color, for menu items.
    private func colorDot(_ color: TabGroupColor) -> NSImage {
        let fill = SidebarColors.group(color)
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func foldClicked() { onToggleFold?() }
}

/// The tab list's table. The table hides a row as soon as the user drags it, also a row with
/// nothing to drag, and does not show it again: the "New Tab" row disappeared until a click.
/// So only rows that can move start a drag.
@MainActor
private final class SidebarTableView: NSTableView {
    var canDragRow: ((Int) -> Bool)?

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        rowIndexes.allSatisfy { canDragRow?($0) ?? true } && super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }
}

/// The fold button. On hover it shows the same box as a tab row (TabRowView).
@MainActor
private final class SidebarHoverButton: NSButton {
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        layer?.backgroundColor = isHovered ? resolved(SidebarColors.hover) : NSColor.clear.cgColor
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
        // A click folds or unfolds the sidebar, so the button moves away from the mouse and gets
        // no "exited" event. Find the hover state again from the mouse location.
        if let window {
            setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateColors()
    }
}

extension SidebarView: NSMenuDelegate {
    /// The right-click menu for the clicked tab row. A group header opens the group panel instead.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        if rows.indices.contains(row), case .group(let id) = rows[row] {
            // An empty menu does not open. Open the panel after the right-click ends.
            DispatchQueue.main.async { [weak self] in self?.showGroupEditor(id) }
            return
        }
        guard let tab = tab(atRow: row) else { return }
        let selection = selectedTabs
        if !multiSelection.isEmpty, selection.count > 1, selection.contains(where: { $0 === tab }) {
            return addGroupItems(for: selection, to: menu)
        }
        // A right-click outside the selection is for that tab only.
        clearMultiSelection()
        menu.addItem(ClosureMenuItem("Pin Tab") { [weak self] in self?.store.pin(tab) })
        menu.addItem(ClosureMenuItem("Copy Address") { tab.copyAddress() })
        if let reader = ReaderMode.menuItem(for: tab) { menu.addItem(reader) }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add Tab to New Group") { [weak self] in self?.addToNewGroup([tab]) })
        let otherGroups = groupsInOrder.filter { $0.id != tab.groupID }
        if !otherGroups.isEmpty {
            let submenu = NSMenu()
            for group in otherGroups {
                let item = ClosureMenuItem(menuTitle(of: group)) { [weak self] in self?.store.add(tab, toGroup: group.id) }
                item.image = colorDot(group.color)
                submenu.addItem(item)
            }
            let addToGroup = NSMenuItem(title: "Add Tab to Group", action: nil, keyEquivalent: "")
            addToGroup.submenu = submenu
            menu.addItem(addToGroup)
        }
        if tab.groupID != nil {
            menu.addItem(ClosureMenuItem("Remove from Group") { [weak self] in self?.store.removeFromGroup(tab) })
        }
        menu.addItem(.separator())
        // With one tab, the new window would be the same as this one.
        let moveToWindow = ClosureMenuItem("Move to Its Own Window") {
            (NSApp.delegate as? AppDelegate)?.moveToNewWindow(tab)
        }
        moveToWindow.isEnabled = store.tabs.count > 1
        menu.addItem(moveToWindow)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Tab") { [weak self] in self?.store.close(tab) })
        let closeOthers = ClosureMenuItem("Close Other Tabs") { [weak self] in self?.store.closeOtherTabs(than: tab) }
        closeOthers.isEnabled = store.tabs.count > 1
        menu.addItem(closeOthers)
    }

    /// The menu for a selection of many tabs: the group items only.
    private func addGroupItems(for tabs: [Tab], to menu: NSMenu) {
        menu.addItem(ClosureMenuItem("Add \(tabs.count) Tabs to New Group") { [weak self] in self?.addToNewGroup(tabs) })
        let groups = groupsInOrder
        guard !groups.isEmpty else { return }
        let submenu = NSMenu()
        for group in groups {
            let item = ClosureMenuItem(menuTitle(of: group)) { [weak self] in
                self?.clearMultiSelection()
                for tab in tabs { self?.store.add(tab, toGroup: group.id) }
            }
            item.image = colorDot(group.color)
            submenu.addItem(item)
        }
        let addToGroup = NSMenuItem(title: "Add \(tabs.count) Tabs to Group", action: nil, keyEquivalent: "")
        addToGroup.submenu = submenu
        menu.addItem(addToGroup)
    }
}

extension Tab {
    /// For "Copy Address" in the tab menus.
    func copyAddress() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
