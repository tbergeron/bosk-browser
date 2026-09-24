import AppKit
import BoskCore
import WebKit

/// Extension action buttons in the top bar: icon, badge text, click to run the action
/// (or show its popup). Only pinned extensions show; the puzzle button at the end lists
/// all of them, with a pin for each. Drag a button to move it.
@MainActor
final class ExtensionActionsView: NSView {
    var currentTab: () -> Tab? = { nil }
    private var buttons: [String: NSButton] = [:]
    private var order: [String] = []
    private let listButton = NSButton()
    private let listPopover = NSPopover()
    /// The button that follows the mouse while the user drags it.
    private var draggedID: String?
    /// While a button is pressed, the press loop uses `order`, so reloads wait until it ends.
    private var isTrackingPress = false
    private var reloadAfterPress = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        listButton.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")
        listButton.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        listButton.isBordered = false
        listButton.contentTintColor = .secondaryLabelColor
        listButton.toolTip = "Extensions"
        listButton.target = self
        listButton.action = #selector(showList)
        listButton.isHidden = true
        addSubview(listButton)
        listPopover.behavior = .transient
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var fittingSize: NSSize {
        let count = order.count + (listButton.isHidden ? 0 : 1)
        return NSSize(width: max(0, CGFloat(count) * 30 - 2), height: 28)
    }

    func reload() {
        guard !isTrackingPress else { return reloadAfterPress = true }
        let contexts = ExtensionManager.shared.loadedContexts
        let ids = contexts.map(\.uniqueIdentifier)
        order = ExtensionToolbarOrder.visible(ids: ids, order: Preferences.extensionOrder,
                                              unpinned: Preferences.unpinnedExtensions)
        for (id, button) in buttons where !order.contains(id) {
            button.removeFromSuperview()
            buttons[id] = nil
        }
        for context in contexts where order.contains(context.uniqueIdentifier) {
            let id = context.uniqueIdentifier
            let button = buttons[id] ?? makeButton(id)
            buttons[id] = button
            update(button, for: context)
        }
        listButton.isHidden = contexts.isEmpty
        reloadListRows()
        needsLayout = true
        superview?.needsLayout = true
    }

    /// One extension changed its icon, badge or title (often, for a blocker's count).
    /// Updates only its button, and the list when it shows.
    func reload(_ context: WKWebExtensionContext) {
        guard !isTrackingPress else { return reloadAfterPress = true }
        if let button = buttons[context.uniqueIdentifier] { update(button, for: context) }
        reloadListRows()
    }

    private func update(_ button: NSButton, for context: WKWebExtensionContext) {
        let action = context.action(for: currentTab())
        button.image = action?.icon(for: NSSize(width: 16, height: 16))
            ?? context.webExtension.icon(for: NSSize(width: 16, height: 16))
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        button.toolTip = action?.label ?? context.webExtension.displayName
        button.setAccessibilityLabel(button.toolTip)
        button.isEnabled = action?.isEnabled ?? true
        (button as? BadgeButton)?.badge = action?.badgeText ?? ""
    }

    /// Rows change in place: a new view under the mouse loses the next click.
    /// A closed list is made again when it opens.
    private func reloadListRows() {
        guard listPopover.isShown else { return }
        (listPopover.contentViewController as? ExtensionsList)?.reloadRows()
    }

    private func makeButton(_ id: String) -> NSButton {
        let button = BadgeButton()
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(clicked(_:))
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.menu = NSMenu()
        button.menu?.addItem(ClosureMenuItem("Manage Extension") { SettingsWindowController.shared.show(pane: .extensions) })
        button.menu?.addItem(.separator())
        button.menu?.addItem(ClosureMenuItem("Remove Extension…") { [weak self] in self?.confirmRemove(id: id) })
        addSubview(button)
        return button
    }

    /// Removing deletes the extension's files, so the user confirms first.
    private func confirmRemove(id: String) {
        guard let window, let context = ExtensionManager.shared.contexts[id] else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \u{201C}\(context.webExtension.displayName ?? id)\u{201D}?"
        alert.informativeText = "Bosk deletes the extension and its files. You can add it again later."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { ExtensionManager.shared.remove(id: id) }
        }
    }

    /// The anchor for the extension's popup: its button, or the puzzle button when it is not pinned.
    func button(for context: WKWebExtensionContext) -> NSView? {
        buttons[context.uniqueIdentifier] ?? (listButton.isHidden ? nil : listButton)
    }

    override func layout() {
        super.layout()
        for (index, id) in order.enumerated() where id != draggedID {
            buttons[id]?.frame = frame(at: index)
        }
        listButton.frame = frame(at: order.count)
    }

    private func frame(at index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * 30, y: 0, width: 28, height: 28)
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let context = ExtensionManager.shared.contexts[id] else { return }
        context.performAction(for: currentTab())
    }

    // MARK: Pins

    func isPinned(_ id: String) -> Bool { order.contains(id) }

    func setPinned(_ pinned: Bool, id: String) {
        if pinned {
            Preferences.extensionOrder = ExtensionToolbarOrder.pinned(id, visible: order, order: Preferences.extensionOrder)
            Preferences.unpinnedExtensions.remove(id)
        } else {
            Preferences.unpinnedExtensions.insert(id)
        }
        ExtensionManager.shared.changed()
    }

    /// From the extensions list: runs the action. A popup shows under the puzzle button.
    func performAction(id: String) {
        listPopover.close()
        ExtensionManager.shared.contexts[id]?.performAction(for: currentTab())
    }

    /// From the extensions list: the footer items close the list, then do their work.
    func openWebStore() {
        listPopover.close()
        (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [URL(string: "https://chromewebstore.google.com")!])
    }

    func manageExtensions() {
        listPopover.close()
        SettingsWindowController.shared.show(pane: .extensions)
    }

    @objc private func showList() {
        if listPopover.isShown { return listPopover.close() }
        listPopover.contentViewController = ExtensionsList(bar: self)
        listPopover.show(relativeTo: listButton.bounds, of: listButton, preferredEdge: .minY)
    }

    // MARK: Drag to move

    /// A click runs the action; a drag moves the button, and the others make room.
    fileprivate func trackPress(on button: NSButton, with event: NSEvent) {
        guard let id = button.identifier?.rawValue, let window, var index = order.firstIndex(of: id) else { return }
        isTrackingPress = true
        defer {
            isTrackingPress = false
            if reloadAfterPress {
                reloadAfterPress = false
                reload()
            }
        }
        let start = convert(event.locationInWindow, from: nil)
        let startX = button.frame.minX
        var isDragging = false
        button.highlight(true)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let point = convert(next.locationInWindow, from: nil)
            if !isDragging {
                guard abs(point.x - start.x) > 3 else { continue }
                isDragging = true
                draggedID = id
                button.highlight(false)
                addSubview(button, positioned: .above, relativeTo: nil)
            }
            let x = min(max(0, startX + point.x - start.x), CGFloat(order.count - 1) * 30)
            button.frame.origin.x = x
            let newIndex = Int((x / 30).rounded())
            if newIndex != index {
                order = TabOrdering.moved(order, from: index, to: newIndex)
                index = newIndex
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    for (other, otherID) in order.enumerated() where otherID != id {
                        buttons[otherID]?.animator().frame = frame(at: other)
                    }
                }
            }
        }
        button.highlight(false)
        guard isDragging else {
            if button.isEnabled { clicked(button) }
            return
        }
        draggedID = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            button.animator().frame = frame(at: index)
        }
        Preferences.extensionOrder = ExtensionToolbarOrder.saved(visible: order, order: Preferences.extensionOrder)
        ExtensionManager.shared.changed()
    }
}

/// The puzzle button's list: every extension, with a pin that shows it in the top bar.
@MainActor
private final class ExtensionsList: NSViewController {
    private weak var bar: ExtensionActionsView?

    init(bar: ExtensionActionsView) {
        self.bar = bar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private let stack = NSStackView()

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        view = stack
        reloadRows()
    }

    func reloadRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = NSTextField(labelWithString: "Extensions")
        title.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(8, after: title)
        for context in ExtensionManager.shared.loadedContexts {
            stack.addArrangedSubview(HoverRowView(row(for: context)))
        }
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        // The same space above and below the line as between the last row and the popup edge.
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(stack.edgeInsets.bottom, after: last) }
        stack.addArrangedSubview(separator)
        stack.setCustomSpacing(stack.edgeInsets.bottom, after: separator)
        stack.addArrangedSubview(footerRow("Chrome Web Store\u{2026}", symbol: "storefront", action: #selector(openStore)))
        stack.addArrangedSubview(footerRow("Manage Extensions\u{2026}", symbol: "gearshape", action: #selector(manage)))
        // The popover takes this size. Without it, the popover is narrower than the rows
        // and they go past the left edge.
        preferredContentSize = stack.fittingSize
    }

    /// Icon, name and pin, with the gaps between them.
    private static let rowWidth: CGFloat = 18 + 210 + 24 + 2 * 8

    private func footerRow(_ title: String, symbol: String, action: Selector) -> NSView {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                              target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.alignment = .left
        button.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return HoverRowView(button)
    }

    @objc private func openStore() { bar?.openWebStore() }
    @objc private func manage() { bar?.manageExtensions() }

    private func row(for context: WKWebExtensionContext) -> NSView {
        let id = context.uniqueIdentifier
        let icon = NSButton(image: context.webExtension.icon(for: NSSize(width: 16, height: 16))
                                ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!,
                            target: self, action: #selector(run(_:)))
        icon.isBordered = false
        icon.imageScaling = .scaleProportionallyDown
        icon.identifier = NSUserInterfaceItemIdentifier(id)
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let name = NSButton(title: context.webExtension.displayName ?? id, target: self, action: #selector(run(_:)))
        name.alignment = .left
        name.isBordered = false
        name.identifier = NSUserInterfaceItemIdentifier(id)
        name.lineBreakMode = .byTruncatingTail
        name.widthAnchor.constraint(equalToConstant: 210).isActive = true
        let pinned = bar?.isPinned(id) ?? false
        let pin = NSButton(image: NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                          accessibilityDescription: pinned ? "Unpin" : "Pin")!,
                           target: self, action: #selector(togglePin(_:)))
        pin.isBordered = false
        pin.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
        pin.toolTip = pinned ? "Unpin from the top bar" : "Pin to the top bar"
        pin.identifier = NSUserInterfaceItemIdentifier(id)
        pin.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let row = NSStackView(views: [icon, name, pin])
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return row
    }

    @objc private func run(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        bar?.performAction(id: id)
    }

    @objc private func togglePin(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let bar else { return }
        bar.setPinned(!bar.isPinned(id), id: id)
    }
}

/// A button with a small badge (an extension's badge text, such as a count).
@MainActor
private final class BadgeButton: NSButton {
    var badge = "" {
        didSet {
            badgeLayer.string = badge
            badgeLayer.isHidden = badge.isEmpty
            // The badge width follows the text length.
            needsLayout = true
        }
    }
    private let badgeLayer = CATextLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        badgeLayer.fontSize = 8
        badgeLayer.font = NSFont.boldSystemFont(ofSize: 8)
        badgeLayer.alignmentMode = .center
        badgeLayer.foregroundColor = NSColor.white.cgColor
        badgeLayer.backgroundColor = NSColor.systemRed.cgColor
        badgeLayer.cornerRadius = 5
        badgeLayer.contentsScale = 2
        badgeLayer.isHidden = true
        layer?.addSublayer(badgeLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        guard let bar = superview as? ExtensionActionsView else { return super.mouseDown(with: event) }
        bar.trackPress(on: self, with: event)
    }

    override func layout() {
        super.layout()
        let width = max(12, CGFloat(badge.count) * 5 + 6)
        badgeLayer.frame = NSRect(x: bounds.maxX - width, y: 0, width: width, height: 10)
    }
}

/// "Add to Bosk" on a Chrome Web Store extension page.
@MainActor
final class AddToBoskButton: NSButton {
    private var extensionID: String?

    init() {
        super.init(frame: .zero)
        title = "Add to Bosk"
        bezelStyle = .push
        controlSize = .small
        target = self
        action = #selector(add)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var fittingSize: NSSize { isHidden ? .zero : super.fittingSize }

    func update(for url: URL?) {
        extensionID = url.flatMap(ChromeExtensionPackage.webStoreExtensionID)
        isHidden = extensionID == nil
        superview?.needsLayout = true
    }

    @objc private func add() {
        guard let extensionID else { return }
        let window = window
        isEnabled = false
        title = "Adding…"
        Task {
            do {
                try await ExtensionManager.shared.installFromWebStore(extensionID: extensionID, in: window)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The extension did not install"
                alert.informativeText = error.localizedDescription
                if let window { await alert.beginSheetModal(for: window) }
            }
            isEnabled = true
            title = "Add to Bosk"
        }
    }
}
