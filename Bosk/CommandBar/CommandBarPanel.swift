import AppKit
import BoskCore

/// The floating bar that opens with Cmd+T (new tab) or Cmd+L (this tab).
/// Type an address or a search; the rows below offer visited sites and open tabs.
/// Up and Down choose a row; Return opens it.
@MainActor
final class CommandBarPanel: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Target { case newTab, currentTab }
    typealias Suggestion = SuggestionRanker.Suggestion

    private let field = NSTextField()
    private let glass = NSGlassEffectView()
    private let tableView = NSTableView()
    private(set) var target: Target = .newTab
    private var onChoose: ((Suggestion, Target) -> Void)?
    private var provider: ((String) async -> [Suggestion])?
    private var suggestions: [Suggestion] = []
    private var queryTask: Task<Void, Never>?

    private let fieldHeight: CGFloat = 56
    private let rowHeight: CGFloat = 40

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Defaults.commandBarWidth, height: 56),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        backgroundColor = .clear
        hasShadow = true
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

        let content = NSView()
        content.addSubview(field)
        content.addSubview(tableView)
        glass.cornerRadius = 16
        glass.contentView = content
        contentView = glass
    }

    override var canBecomeKey: Bool { true }

    func present(over window: NSWindow, text: String, target: Target,
                 provider: @escaping (String) async -> [Suggestion],
                 onChoose: @escaping (Suggestion, Target) -> Void) {
        self.target = target
        self.onChoose = onChoose
        self.provider = provider
        field.stringValue = text
        suggestions = []
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
    }

    func dismiss() {
        queryTask?.cancel()
        parent?.removeChildWindow(self)
        orderOut(nil)
        onChoose = nil
        provider = nil
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    // MARK: Suggestions

    func controlTextDidChange(_ notification: Notification) {
        let text = field.stringValue
        queryTask?.cancel()
        queryTask = Task { [weak self] in
            guard let provider = self?.provider else { return }
            let rows = await provider(text)
            guard !Task.isCancelled, let self else { return }
            self.suggestions = rows
            self.tableView.reloadData()
            if !rows.isEmpty { self.tableView.selectRowIndexes([0], byExtendingSelection: false) }
            self.resizeForRows()
        }
    }

    /// The top edge stays in place; the panel grows down.
    private func resizeForRows() {
        let height = fieldHeight + CGFloat(suggestions.count) * rowHeight + (suggestions.isEmpty ? 0 : 8)
        var frame = self.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        setFrame(frame, display: true)
        layoutContent()
    }

    private func layoutContent() {
        let size = frame.size
        field.frame = NSRect(x: 18, y: size.height - fieldHeight + 15, width: size.width - 36, height: 26)
        tableView.frame = NSRect(x: 6, y: 4, width: size.width - 12, height: CGFloat(suggestions.count) * rowHeight)
        tableView.tableColumns.first?.width = size.width - 12
    }

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SuggestionCell.identifier, owner: nil) as? SuggestionCell
            ?? SuggestionCell()
        cell.configure(suggestions[row])
        return cell
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

    private func moveSelection(by offset: Int) {
        guard !suggestions.isEmpty else { return }
        let row = min(max(0, tableView.selectedRow + offset), suggestions.count - 1)
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func submit() {
        let row = tableView.selectedRow
        let text = field.stringValue
        // Rows can be one keystroke old; with no rows, go to the typed text directly.
        let choice: Suggestion? = suggestions.indices.contains(row)
            ? suggestions[row]
            : InputClassifier.url(for: text, searchURL: Defaults.searchURL).map(Suggestion.typed)
        choose(choice)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard suggestions.indices.contains(row) else { return }
        choose(suggestions[row])
    }

    private func choose(_ choice: Suggestion?) {
        let target = target
        let onChoose = onChoose
        dismiss()
        if let choice { onChoose?(choice, target) }
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
