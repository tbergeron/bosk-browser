import AppKit

/// One row in the tab list: favicon, title, and a close button on hover.
/// Colors change on layers only, so hover and selection do not redraw text.
@MainActor
final class TabRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("TabRow")

    var onClose: (() -> Void)?

    private let backgroundLayer = CALayer()
    private let iconLayer = CALayer()
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isCurrent = false
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

    func configure(title: String, icon: NSImage?, isCurrent: Bool, isCompact: Bool, isNewTabRow: Bool = false) {
        self.isCurrent = isCurrent
        self.isCompact = isCompact
        titleField.stringValue = title
        titleField.textColor = isNewTabRow ? .secondaryLabelColor : .labelColor
        titleField.isHidden = isCompact
        // Also in the open sidebar, where a long title is cut off.
        toolTip = title
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
        backgroundLayer.frame = bounds.insetBy(dx: isCompact ? 8 : 6, dy: 1)
        let iconSize: CGFloat = 16
        if isCompact {
            iconLayer.frame = NSRect(x: bounds.midX - iconSize / 2, y: bounds.midY - iconSize / 2,
                                     width: iconSize, height: iconSize)
        } else {
            iconLayer.frame = NSRect(x: 16, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize)
            closeButton.frame = NSRect(x: bounds.maxX - 34, y: bounds.midY - 11, width: 22, height: 22)
            let titleRight = closeButton.isHidden ? bounds.maxX - 14 : closeButton.frame.minX - 4
            titleField.frame = NSRect(x: 42, y: bounds.midY - 8, width: max(0, titleRight - 42), height: 17)
        }
        CATransaction.commit()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        if isCurrent {
            backgroundLayer.backgroundColor = resolved(SidebarColors.selected)
            backgroundLayer.shadowOpacity = effectiveAppearance.isDark ? 0 : 0.08
            backgroundLayer.shadowRadius = 2
            backgroundLayer.shadowOffset = CGSize(width: 0, height: -1)
        } else {
            backgroundLayer.backgroundColor = isHovered ? resolved(SidebarColors.hover) : NSColor.clear.cgColor
            backgroundLayer.shadowOpacity = 0
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
    }

    @objc private func closeClicked() { onClose?() }
}
