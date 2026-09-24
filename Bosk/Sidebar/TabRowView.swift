import AppKit

/// One row in the tab list: favicon, title, and a close button on hover.
/// Colors change on layers only, so hover and selection do not redraw text.
@MainActor
final class TabRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("TabRow")

    var onClose: (() -> Void)?

    private let backgroundLayer = CALayer()
    private let iconLayer = CALayer()
    /// The color bar at the left edge of a grouped tab.
    private let groupBarLayer = CALayer()
    /// Folded sidebar: the group's tinted box, in place of the bar (see TabGroupRowView).
    private let groupTintLayer = CALayer()
    private var groupColor: NSColor?
    private var isLastInGroup = false
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isCurrent = false
    /// Cmd+clicked into the selection of many tabs.
    private var isMultiSelected = false
    /// "plus" or "globe" when the row has no favicon.
    private var symbolName: String?
    private var isHovered = false
    /// Folded sidebar: icon only, centered.
    private(set) var isCompact = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        wantsLayer = true
        backgroundLayer.cornerRadius = 8
        backgroundLayer.cornerCurve = .continuous
        layer?.addSublayer(backgroundLayer)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.cornerRadius = 3
        iconLayer.masksToBounds = true
        layer?.addSublayer(iconLayer)
        groupBarLayer.cornerRadius = 2
        layer?.addSublayer(groupBarLayer)
        groupTintLayer.cornerRadius = 10
        groupTintLayer.cornerCurve = .continuous
        layer?.insertSublayer(groupTintLayer, at: 0)

        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = .labelColor
        addSubview(titleField)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// - Parameters:
    ///   - groupColor: The color of the tab's group; nil for a tab with no group.
    ///   - isLastInGroup: The bar ends at this row.
    ///   - isMultiSelected: The tab is in the selection of many tabs (Cmd+click).
    func configure(title: String, icon: NSImage?, isCurrent: Bool, isCompact: Bool, isNewTabRow: Bool = false,
                   groupColor: NSColor? = nil, isLastInGroup: Bool = false, isMultiSelected: Bool = false) {
        self.isCurrent = isCurrent
        self.isMultiSelected = isMultiSelected
        self.isCompact = isCompact
        self.groupColor = groupColor
        self.isLastInGroup = isLastInGroup
        groupBarLayer.isHidden = groupColor == nil || isCompact
        groupTintLayer.isHidden = groupColor == nil || !isCompact
        titleField.stringValue = title
        titleField.textColor = isNewTabRow ? .secondaryLabelColor : .labelColor
        titleField.isHidden = isCompact
        // Also in the open sidebar, where a long title is cut off. The folded sidebar shows
        // only icons, so there the title shows at once (SidebarTooltip).
        toolTip = isCompact ? nil : title
        if isCompact, isHovered { SidebarTooltip.show(title, for: self) }
        symbolName = icon == nil ? (isNewTabRow ? "plus" : "globe") : nil
        iconLayer.contents = icon ?? symbolImage()
        iconLayer.opacity = icon == nil && !isNewTabRow ? 0.5 : 1
        closeButton.isHidden = isNewTabRow || isCompact || !(isHovered || isCurrent)
        onClose = isNewTabRow ? nil : onClose
        setAccessibilityLabel(title)
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Folded: the row has 2 pt (half the space between tab boxes) above and below the tab's box.
        // In a group, the box is 2 pt smaller, so it stays inside the group's tinted box.
        backgroundLayer.frame = !isCompact ? bounds.insetBy(dx: 6, dy: 1)
            : groupColor == nil ? bounds.insetBy(dx: 8, dy: 2) : bounds.insetBy(dx: 10, dy: 4)
        // Past the row edges, so the bars of the rows in a group join into one bar. On the last row,
        // the bar stops at the bottom of the tab's background. Rows are flipped: y = 0 is the top.
        let barBottom = isLastInGroup ? backgroundLayer.frame.maxY : bounds.height + 2
        groupBarLayer.frame = NSRect(x: 0, y: -2, width: 4, height: barBottom + 2)
        // The last row closes the box with round bottom corners ("max Y" is the bottom here).
        groupTintLayer.frame = NSRect(x: 6, y: 0, width: bounds.width - 12, height: bounds.height - (isLastInGroup ? 2 : 0))
        groupTintLayer.maskedCorners = isLastInGroup ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : []
        let iconSize: CGFloat = 16
        let indent: CGFloat = groupColor == nil ? 0 : 8
        if isCompact {
            iconLayer.frame = NSRect(x: bounds.midX - iconSize / 2, y: bounds.midY - iconSize / 2,
                                     width: iconSize, height: iconSize)
        } else {
            iconLayer.frame = NSRect(x: 16 + indent, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize)
            closeButton.frame = NSRect(x: bounds.maxX - 34, y: bounds.midY - 11, width: 22, height: 22)
            let titleRight = closeButton.isHidden ? bounds.maxX - 14 : closeButton.frame.minX - 4
            let titleLeft = 42 + indent
            titleField.frame = NSRect(x: titleLeft, y: bounds.midY - 8, width: max(0, titleRight - titleLeft), height: 17)
        }
        CATransaction.commit()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        if isCurrent {
            backgroundLayer.backgroundColor = resolved(SidebarColors.currentTab)
            backgroundLayer.borderColor = resolved(SidebarColors.currentTabRing)
            backgroundLayer.borderWidth = 1
            backgroundLayer.shadowOpacity = effectiveAppearance.isDark ? 0 : 0.08
            backgroundLayer.shadowRadius = 2
            backgroundLayer.shadowOffset = CGSize(width: 0, height: -1)
        } else if isMultiSelected {
            backgroundLayer.backgroundColor = resolved(SidebarColors.multiSelected)
            backgroundLayer.borderWidth = 0
            backgroundLayer.shadowOpacity = 0
        } else {
            backgroundLayer.backgroundColor = isHovered ? resolved(SidebarColors.hover) : NSColor.clear.cgColor
            backgroundLayer.borderWidth = 0
            backgroundLayer.shadowOpacity = 0
        }
        if let groupColor {
            groupBarLayer.backgroundColor = resolved(groupColor)
            groupTintLayer.backgroundColor = resolved(groupColor.withAlphaComponent(SidebarColors.groupTintAlpha))
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if symbolName != nil { iconLayer.contents = symbolImage() }
        updateColors()
    }

    /// A layer draws a symbol black in every appearance: draw it in the label color of this row.
    private func symbolImage() -> NSImage? {
        guard let symbolName, let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
        let color = NSColor(cgColor: resolved(.labelColor)) ?? .labelColor
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    // Selection is drawn by `backgroundLayer`, not by NSTableView.
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only this view's own area: the tooltip has a tracking area too.
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        isHovered = hovered
        if isCompact, hovered { SidebarTooltip.show(titleField.stringValue, for: self) } else { SidebarTooltip.hide(for: self) }
        if onClose != nil, !isCompact {
            closeButton.isHidden = !(hovered || isCurrent)
            needsLayout = true
        }
        updateColors()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        onClose = nil
        SidebarTooltip.hide(for: self)
    }

    @objc private func closeClicked() { onClose?() }
}
