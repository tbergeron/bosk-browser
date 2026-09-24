import AppKit

/// The header row of a tab group: its name in the group color, and the top of the color bar.
/// A click folds or unfolds the group (see `SidebarView`).
@MainActor
final class TabGroupRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("TabGroupRow")

    private let backgroundLayer = CALayer()
    private let barLayer = CALayer()
    /// Folded sidebar: the top of a box in the group color, around the group's tab icons.
    private let tintLayer = CALayer()
    private let titleField = NSTextField(labelWithString: "")
    /// Folded sidebar: the first letter of the name (or the number of tabs), in place of the name.
    private let letterField = NSTextField(labelWithString: "")
    private var color: NSColor = .labelColor
    private var isHovered = false
    private var isCompact = false
    /// No tab row below: a folded group whose tabs are all hidden.
    private var endsHere = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        wantsLayer = true
        backgroundLayer.cornerRadius = 8
        backgroundLayer.cornerCurve = .continuous
        layer?.addSublayer(backgroundLayer)
        barLayer.cornerRadius = 2
        layer?.addSublayer(barLayer)
        tintLayer.cornerRadius = 10
        tintLayer.cornerCurve = .continuous
        layer?.insertSublayer(tintLayer, at: 0)
        letterField.font = .systemFont(ofSize: 13, weight: .bold)
        letterField.alignment = .center
        addSubview(letterField)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// - Parameters:
    ///   - title: The group name; empty shows the number of tabs.
    ///   - endsHere: No tab of the group shows below this row.
    func configure(title: String, tabCount: Int, color: NSColor, isFolded: Bool, isCompact: Bool, endsHere: Bool) {
        self.color = color
        self.isCompact = isCompact
        self.endsHere = endsHere
        let name = title.isEmpty ? (tabCount == 1 ? "1 Tab" : "\(tabCount) Tabs") : title
        titleField.stringValue = name
        titleField.textColor = title.isEmpty ? .secondaryLabelColor : color
        titleField.isHidden = isCompact
        barLayer.isHidden = isCompact
        tintLayer.isHidden = !isCompact
        letterField.isHidden = !isCompact
        letterField.stringValue = title.isEmpty ? "\(tabCount)" : String(title.prefix(1)).uppercased()
        letterField.textColor = color
        // The folded sidebar shows the name at once (SidebarTooltip).
        toolTip = isCompact ? nil : name
        if isCompact, isHovered { SidebarTooltip.show(name, for: self) }
        setAccessibilityLabel("\(name), group, \(isFolded ? "folded" : "unfolded")")
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Folded: 2 pt inside the tinted box.
        backgroundLayer.frame = isCompact ? bounds.insetBy(dx: 10, dy: 6) : bounds.insetBy(dx: 6, dy: 1)
        // From the top of the header's background to past the bottom edge, where the first tab's bar
        // starts. With no tab below, it stops at the bottom of the background.
        let barTop = backgroundLayer.frame.minY
        let barBottom = endsHere ? backgroundLayer.frame.maxY : bounds.height + 2
        barLayer.frame = NSRect(x: 0, y: barTop, width: 4, height: barBottom - barTop)
        // Rows are flipped: y = 0 and the "min Y" corners are at the top. The box goes on in the
        // tab rows below (TabRowView), so only its top corners are round, unless no tab follows.
        // 4 pt (half the space between items in the strip) from the row edges, as a tab's box.
        tintLayer.frame = NSRect(x: 6, y: 4, width: bounds.width - 12, height: bounds.height - (endsHere ? 8 : 4))
        tintLayer.maskedCorners = endsHere
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        letterField.frame = NSRect(x: 0, y: bounds.midY - 9, width: bounds.width, height: 18)
        titleField.frame = NSRect(x: 16, y: bounds.midY - 8, width: max(0, bounds.width - 30), height: 17)
        CATransaction.commit()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        backgroundLayer.backgroundColor = isHovered ? resolved(SidebarColors.hover) : NSColor.clear.cgColor
        barLayer.backgroundColor = resolved(color)
        tintLayer.backgroundColor = resolved(color.withAlphaComponent(SidebarColors.groupTintAlpha))
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateColors()
        if isCompact { SidebarTooltip.show(titleField.stringValue, for: self) }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateColors()
        SidebarTooltip.hide(for: self)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        SidebarTooltip.hide(for: self)
    }
}
