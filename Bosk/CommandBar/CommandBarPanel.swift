import AppKit
import BoskCore

/// The floating bar that opens with Cmd+T (new tab) or Cmd+L (this tab).
/// Type an address or a search; the rows below offer visited sites, bookmarks and open tabs.
/// Up and Down choose a row; Return opens it.
///
/// The same bar also shows the lists (Search Tabs, History, Bookmarks, Search Commands): the list shows
/// at once, and the text filters it.
@MainActor
final class CommandBarPanel: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Target { case newTab, currentTab }
    enum Mode { case open, tabs, history, bookmarks, commands }
    /// A row of the table: a section header ("Today") or a row the user can choose.
    enum Row {
        case header(String)
        case item(SuggestionRanker.Suggestion)
    }
    typealias Suggestion = SuggestionRanker.Suggestion

    private let field = NSTextField()
    private let glass = NSGlassEffectView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private(set) var target: Target = .newTab
    private(set) var mode: Mode = .open
    private var onChoose: ((Suggestion, Target) -> Void)?
    private var onRemove: ((Suggestion) async -> Void)?
    private var provider: ((String) async -> [Row])?
    private var rows: [Row] = []
    /// The text that `rows` were made for. Rows arrive later than the keystrokes.
    private var rowsQuery = ""
    private var queryTask: Task<Void, Never>?

    private let fieldHeight: CGFloat = 56
    private let rowHeight: CGFloat = 40
    private let headerHeight: CGFloat = 28
    /// The space between the list and the edges of the glass: left and right.
    private let listInset: CGFloat = 6
    /// The bottom is 2 points more: the light bottom edge of the glass makes an equal space look smaller.
    private let listBottomInset: CGFloat = 8
    private let cornerRadius: CGFloat = 16

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Defaults.commandBarWidth, height: 56),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        // Only the round glass shows. An opaque window fills the corners outside its curve.
        isOpaque = false
        backgroundColor = .clear
        // The window shadow of a borderless panel draws a thin dark line around the glass.
        hasShadow = false
        isReleasedWhenClosed = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.placeholderString = "Search or enter address"
        field.delegate = self
        // Return sends the action (also reachable by accessibility "confirm").
        field.target = self
        field.action = #selector(submit)
        field.cell?.sendsActionOnEndEditing = false
        field.cell?.isScrollable = true
        field.cell?.wraps = false

        tableView.addTableColumn(NSTableColumn(identifier: .init("row")))
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.focusRingType = .none
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let content = NSView()
        content.addSubview(field)
        content.addSubview(scrollView)
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        glass.autoresizingMask = [.width, .height]
        // The glass is round, but its backdrop is not: this clip keeps the corners clear.
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.addSubview(glass)
        contentView = clip
        glass.frame = clip.bounds
    }

    override var canBecomeKey: Bool { true }

    func present(over window: NSWindow, text: String, target: Target, mode: Mode = .open,
                 provider: @escaping (String) async -> [Row],
                 onChoose: @escaping (Suggestion, Target) -> Void,
                 onRemove: ((Suggestion) async -> Void)? = nil) {
        self.target = target
        self.mode = mode
        self.onChoose = onChoose
        self.onRemove = onRemove
        self.provider = provider
        field.stringValue = text
        field.placeholderString = switch mode {
        case .open: "Search or enter address"
        case .tabs: "Search tabs"
        case .history: "Search history"
        case .bookmarks: "Search bookmarks"
        case .commands: "Search commands"
        }
        rows = []
        rowsQuery = ""
        tableView.reloadData()

        let frame = window.frame
        let top = frame.maxY - frame.height * 0.22
        setFrame(NSRect(x: frame.midX - Defaults.commandBarWidth / 2, y: top - fieldHeight,
                        width: Defaults.commandBarWidth, height: fieldHeight), display: false)
        layoutContent()

        if parent == nil { window.addChildWindow(self, ordered: .above) }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        // A list shows at once, before the user types.
        if mode != .open { runQuery(text) }
    }

    func dismiss() {
        queryTask?.cancel()
        parent?.removeChildWindow(self)
        orderOut(nil)
        onChoose = nil
        onRemove = nil
        provider = nil
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    // MARK: Suggestions

    func controlTextDidChange(_ notification: Notification) {
        runQuery(field.stringValue, debounce: true)
    }

    /// - Parameter debounce: Waits a short time first, so fast typing runs one history search.
    private func runQuery(_ text: String, debounce: Bool = false) {
        queryTask?.cancel()
        queryTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(50)) }
            guard !Task.isCancelled, let provider = self?.provider else { return }
            let rows = await provider(text)
            guard !Task.isCancelled, let self else { return }
            self.rows = rows
            self.rowsQuery = text
            self.tableView.reloadData()
            if let first = rows.firstIndex(where: Self.isSelectable) {
                self.tableView.selectRowIndexes([first], byExtendingSelection: false)
            }
            self.tableView.scrollRowToVisible(0)
            self.resizeForRows()
        }
    }

    private var listHeight: CGFloat {
        let content = rows.reduce(0) { $0 + height(of: $1) }
        return min(content, CGFloat(Defaults.commandBarMaxVisibleRows) * rowHeight)
    }

    private func height(of row: Row) -> CGFloat {
        if case .header = row { headerHeight } else { rowHeight }
    }

    /// The top edge stays in place; the panel grows down.
    private func resizeForRows() {
        let height = fieldHeight + listHeight + (rows.isEmpty ? 0 : listInset + listBottomInset)
        var frame = self.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        setFrame(frame, display: true)
        layoutContent()
    }

    private func layoutContent() {
        let size = frame.size
        field.frame = NSRect(x: 18, y: size.height - fieldHeight + 15, width: size.width - 36, height: 26)
        scrollView.frame = NSRect(x: listInset, y: listBottomInset, width: size.width - listInset * 2, height: listHeight)
        tableView.tableColumns.first?.width = size.width - listInset * 2
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        height(of: rows[row])
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = tableView.makeView(withIdentifier: RoundRowView.identifier, owner: nil) as? RoundRowView
            ?? RoundRowView()
        // The row curve follows the glass curve at the list inset.
        rowView.cornerRadius = cornerRadius - listInset
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        Self.isSelectable(rows[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: HeaderCell.identifier, owner: nil) as? HeaderCell
                ?? HeaderCell()
            cell.configure(title)
            return cell
        case .item(let suggestion):
            let cell = tableView.makeView(withIdentifier: SuggestionCell.identifier, owner: nil) as? SuggestionCell
                ?? SuggestionCell()
            cell.configure(suggestion)
            return cell
        }
    }

    /// The right-click menu of a History or Bookmarks row.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard let onRemove, rows.indices.contains(row), case .item(let suggestion) = rows[row] else { return }
        let title: String
        switch suggestion {
        case .visit: title = "Remove from History"
        case .bookmark: title = "Remove Bookmark"
        default: return
        }
        menu.addItem(ClosureMenuItem(title) { [weak self] in
            Task {
                await onRemove(suggestion)
                // The list shows the change only after the remove is done.
                if let self { self.runQuery(self.field.stringValue) }
            }
        })
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        default:
            return false
        }
        return true
    }

    /// Goes to the next row the user can choose. Headers and commands that are off are skipped.
    private func moveSelection(by offset: Int) {
        var row = tableView.selectedRow + offset
        while rows.indices.contains(row) {
            if Self.isSelectable(rows[row]) {
                tableView.selectRowIndexes([row], byExtendingSelection: false)
                // Show the header above the first row of a section too.
                tableView.scrollRowToVisible(offset < 0 && row > 0 ? row - 1 : row)
                tableView.scrollRowToVisible(row)
                return
            }
            row += offset
        }
    }

    /// Headers and menu commands that are off cannot be chosen.
    private static func isSelectable(_ row: Row) -> Bool {
        switch row {
        case .header: false
        case .item(.command(_, _, _, _, let isEnabled)): isEnabled
        case .item: true
        }
    }

    private func suggestion(at row: Int) -> Suggestion? {
        guard rows.indices.contains(row), Self.isSelectable(rows[row]), case .item(let suggestion) = rows[row] else { return nil }
        return suggestion
    }

    @objc private func submit() {
        let text = field.stringValue
        // Rows can be one keystroke old. In the open mode, the first row is then the old typed
        // text, so go to the text in the field.
        if mode != .open || rowsQuery == text, let choice = suggestion(at: tableView.selectedRow) {
            choose(choice)
        } else if mode == .open {
            choose(InputClassifier.url(for: text, searchURL: Defaults.searchURL).map(Suggestion.typed))
        }
    }

    @objc private func rowClicked() {
        guard let choice = suggestion(at: tableView.clickedRow) else { return }
        choose(choice)
    }

    private func choose(_ choice: Suggestion?) {
        let target = target
        let onChoose = onChoose
        dismiss()
        if let choice { onChoose?(choice, target) }
    }
}

/// A row whose selection has round corners, to match the round glass.
@MainActor
private final class RoundRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("RoundRow")
    var cornerRadius: CGFloat = 0

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawSelection(in dirtyRect: NSRect) {
        // The same colors as the plain selection.
        (isEmphasized ? NSColor.selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
}

/// One suggestion row: icon, title, and the address or "Switch to Tab".
@MainActor
private final class SuggestionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("Suggestion")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.alignment = .right
        [icon, title, detail].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ suggestion: SuggestionRanker.Suggestion) {
        // Cells are reused: only a command that is off is gray.
        title.textColor = .labelColor
        detail.textColor = .secondaryLabelColor
        switch suggestion {
        case .typed(let url):
            let isSearch = url.absoluteString.hasPrefix(Defaults.searchURL.absoluteString)
            icon.image = NSImage(systemSymbolName: isSearch ? "magnifyingglass" : "globe", accessibilityDescription: nil)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value
            title.stringValue = isSearch ? (query ?? url.absoluteString) : url.absoluteString
            detail.stringValue = isSearch ? "Search Google" : "Open"
        case .openTab(_, let tabTitle, let url):
            icon.image = FaviconStore.shared.cachedIcon(for: url)
                ?? NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)
            title.stringValue = tabTitle.isEmpty ? (url?.host() ?? "Tab") : tabTitle
            detail.stringValue = "Switch to Tab"
        case .history(let historyTitle, let url):
            icon.image = FaviconStore.shared.cachedIcon(for: url)
                ?? NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            title.stringValue = historyTitle.isEmpty ? url.absoluteString : historyTitle
            detail.stringValue = url.host() ?? ""
        case .bookmark(_, let bookmarkTitle, let url):
            icon.image = FaviconStore.shared.cachedIcon(for: url)
                ?? NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
            title.stringValue = bookmarkTitle.isEmpty ? url.absoluteString : bookmarkTitle
            detail.stringValue = url.host() ?? ""
        case .visit(let visitTitle, let url, let lastVisit):
            icon.image = FaviconStore.shared.cachedIcon(for: url)
                ?? NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            title.stringValue = visitTitle.isEmpty ? url.absoluteString : visitTitle
            detail.stringValue = lastVisit.formatted(date: .omitted, time: .shortened)
        case .command(_, let commandTitle, _, let shortcut, let isEnabled):
            icon.image = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
            title.stringValue = commandTitle
            detail.stringValue = shortcut
            if !isEnabled {
                title.textColor = .tertiaryLabelColor
                detail.textColor = .tertiaryLabelColor
            }
        }
        setAccessibilityLabel("\(title.stringValue), \(detail.stringValue)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        icon.frame = NSRect(x: 12, y: midY - 8, width: 16, height: 16)
        let detailWidth = min(220, bounds.width * 0.35)
        detail.frame = NSRect(x: bounds.maxX - detailWidth - 12, y: midY - 8, width: detailWidth, height: 16)
        title.frame = NSRect(x: 38, y: midY - 9, width: detail.frame.minX - 46, height: 18)
    }
}

/// A section header in a list: "Today", "Open Tabs".
@MainActor
private final class HeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("Header")
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 12, y: 4, width: bounds.width - 24, height: 16)
    }
}
