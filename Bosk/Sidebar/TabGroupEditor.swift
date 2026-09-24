import AppKit
import BoskCore

/// The panel for a tab group: its name, its color, and the group actions.
/// It opens in a popover from the group header. Changes apply at once.
@MainActor
final class TabGroupEditor: NSViewController, NSTextFieldDelegate {
    struct Actions {
        var newTab: () -> Void
        var moveToNewWindow: (() -> Void)?
        var close: () -> Void
        var ungroup: () -> Void
        /// Closes the popover.
        var dismiss: () -> Void
    }

    private let store: TabStore
    private let groupID: UUID
    private let actions: Actions
    private let nameField = NSTextField()
    private var colorButtons: [ColorDot] = []

    init(store: TabStore, groupID: UUID, actions: Actions) {
        self.store = store
        self.groupID = groupID
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let group = store.group(groupID)
        nameField.stringValue = group?.title ?? ""
        nameField.placeholderString = "Group Name"
        nameField.font = .systemFont(ofSize: 13)
        nameField.delegate = self

        colorButtons = TabGroupColor.allCases.map { color in
            let dot = ColorDot(color: color)
            dot.isChosen = color == group?.color
            dot.target = self
            dot.action = #selector(colorClicked(_:))
            return dot
        }
        let colors = NSStackView(views: colorButtons)
        colors.spacing = 5.5

        let moveButton = actionButton("Move Group to New Window", "macwindow.badge.plus", #selector(moveClicked))
        moveButton.isEnabled = actions.moveToNewWindow != nil
        let firstSeparator = separator()
        let closeGroup = HoverRowView(actionButton("Close Group", "xmark.square", #selector(closeClicked)))
        let secondSeparator = separator()
        let rows: [NSView] = [
            nameField, colors, firstSeparator,
            HoverRowView(actionButton("New Tab in Group", "plus.square.on.square", #selector(newTabClicked))),
            HoverRowView(moveButton), closeGroup,
            secondSeparator,
            HoverRowView(actionButton("Ungroup", "square.dashed", #selector(ungroupClicked))),
        ]

        // The same spacing as the extensions popover (ExtensionToolbar.swift).
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.setCustomSpacing(12, after: nameField)
        // The same space above and below a line as between the rows and the popover edge.
        for view in [colors, firstSeparator, closeGroup, secondSeparator] {
            stack.setCustomSpacing(stack.edgeInsets.bottom, after: view)
        }
        for row in rows where row !== colors {
            row.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        }
        view = stack
        preferredContentSize = stack.fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    /// As wide as the color dots: 9 dots of 20 pt, 5.5 pt apart.
    private static let rowWidth: CGFloat = 224

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func actionButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                              target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: 13)
        button.contentTintColor = .labelColor
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    // MARK: Actions

    func controlTextDidChange(_ notification: Notification) {
        store.updateGroup(groupID, title: nameField.stringValue)
    }

    /// Return and Escape close the panel, as in other browsers.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        actions.dismiss()
        return true
    }

    @objc private func colorClicked(_ sender: ColorDot) {
        store.updateGroup(groupID, color: sender.color)
        for dot in colorButtons { dot.isChosen = dot === sender }
    }

    @objc private func newTabClicked() { actions.dismiss(); actions.newTab() }
    @objc private func moveClicked() { actions.dismiss(); actions.moveToNewWindow?() }
    @objc private func closeClicked() { actions.dismiss(); actions.close() }
    @objc private func ungroupClicked() { actions.dismiss(); actions.ungroup() }
}

/// One color choice: a dot, with a ring when it is the group's color. The dot grows under the pointer.
@MainActor
final class ColorDot: NSButton {
    let color: TabGroupColor
    var isChosen = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }

    init(color: TabGroupColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        title = ""
        setAccessibilityLabel(color.rawValue.capitalized)
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let fill = SidebarColors.group(color)
        if isChosen {
            fill.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
            fill.setFill()
            let inset: CGFloat = isHovered ? 3.5 : 5
            NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).fill()
        } else {
            fill.setFill()
            let inset: CGFloat = isHovered ? 0 : 2.5
            NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}
