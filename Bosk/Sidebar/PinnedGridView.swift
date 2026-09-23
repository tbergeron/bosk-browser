import AppKit
import BoskCore

/// Pinned tabs as favicon tiles: 3 or more columns when the sidebar is open, 1 column in the strip.
@MainActor
final class PinnedGridView: NSView {
    var onSelect: ((Tab) -> Void)?
    var onUnpin: ((Tab) -> Void)?
    var onClose: ((Tab) -> Void)?
    /// A tab (by UUID string) was dropped at this insertion index.
    var onDrop: ((String, Int) -> Void)?
    /// While a tab is dragged, an empty grid still shows a place to drop it.
    var isShowingDropZone = false {
        didSet { dropZoneLayer.isHidden = !(isShowingDropZone && tiles.isEmpty) }
    }

    private(set) var tiles: [PinnedTileView] = []
    private let dropZoneLayer = CALayer()
    private let insertionLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dropZoneLayer.cornerRadius = 10
        dropZoneLayer.borderWidth = 1.5
        dropZoneLayer.isHidden = true
        layer?.addSublayer(dropZoneLayer)
        insertionLayer.cornerRadius = 1.5
        insertionLayer.isHidden = true
        layer?.addSublayer(insertionLayer)
        registerForDraggedTypes([.boskTab])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    /// Folded sidebar: one column.
    var isCompact = false { didSet { needsLayout = true } }
    let spacing: CGFloat = 8
    var tileHeight: CGFloat { isCompact ? 44 : 52 }
    /// About the tile width in a sidebar of the default width (3 columns).
    private let preferredTileWidth: CGFloat = 72
    private var columns: Int { columns(forWidth: bounds.width) }

    /// A wider sidebar gets more tiles in a row, not wider tiles. Never fewer than 3.
    private func columns(forWidth width: CGFloat) -> Int {
        guard !isCompact else { return 1 }
        return max(3, Int(((width + spacing) / (preferredTileWidth + spacing)).rounded()))
    }

    override var isFlipped: Bool { true }

    func reload(tabs: [Tab], selected: Tab?) {
        // Reuse tile views; only the count changes.
        while tiles.count > tabs.count { tiles.removeLast().removeFromSuperview() }
        while tiles.count < tabs.count {
            let tile = PinnedTileView()
            addSubview(tile)
            tiles.append(tile)
        }
        for (tile, tab) in zip(tiles, tabs) {
            tile.tab = tab
            tile.configure(isCurrent: tab === selected)
            tile.onClick = { [weak self] in self?.onSelect?(tab) }
            tile.menu = menu(for: tab)
        }
        needsLayout = true
    }

    func update(_ tab: Tab, selected: Tab?) {
        tiles.first { $0.tab === tab }?.configure(isCurrent: tab === selected)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard !tiles.isEmpty else { return isShowingDropZone ? tileHeight : 0 }
        let columns = columns(forWidth: width)
        let rows = (tiles.count + columns - 1) / columns
        return CGFloat(rows) * tileHeight + CGFloat(rows - 1) * spacing
    }

    func tileFrame(at index: Int) -> NSRect {
        let width = (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let column = index % columns
        let row = index / columns
        return NSRect(x: CGFloat(column) * (width + spacing), y: CGFloat(row) * (tileHeight + spacing),
                      width: width, height: tileHeight)
    }

    override func layout() {
        super.layout()
        for (index, tile) in tiles.enumerated() { tile.frame = tileFrame(at: index) }
        dropZoneLayer.frame = bounds
        dropZoneLayer.borderColor = resolved(.tertiaryLabelColor)
        insertionLayer.backgroundColor = resolved(.controlAccentColor)
    }

    // MARK: Drop

    private func insertionIndex(for info: NSDraggingInfo) -> Int {
        let point = convert(info.draggingLocation, from: nil)
        let width = (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        return TabOrdering.gridInsertionIndex(x: point.x, y: point.y, columns: columns, tileWidth: width,
                                              tileHeight: tileHeight, spacing: spacing, count: tiles.count)
    }

    /// A thin bar where the tile will go.
    private func showInsertion(at index: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !tiles.isEmpty else {
            insertionLayer.isHidden = true
            return
        }
        let reference = tileFrame(at: min(index, tiles.count - 1))
        let x = index < tiles.count ? reference.minX - spacing / 2 : reference.maxX + spacing / 2
        let isVertical = columns > 1
        insertionLayer.frame = isVertical
            ? NSRect(x: x - 1.5, y: reference.minY, width: 3, height: reference.height)
            : NSRect(x: reference.minX, y: (index < tiles.count ? reference.minY : reference.maxY) - spacing / 2 - 1.5,
                     width: reference.width, height: 3)
        insertionLayer.isHidden = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .boskTab) != nil else { return [] }
        showInsertion(at: columns == 1 ? verticalIndex(for: sender) : insertionIndex(for: sender))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        insertionLayer.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertionLayer.isHidden = true
        guard let id = sender.draggingPasteboard.string(forType: .boskTab) else { return false }
        onDrop?(id, columns == 1 ? verticalIndex(for: sender) : insertionIndex(for: sender))
        return true
    }

    /// In the one-column strip, the top half of a tile inserts before it.
    private func verticalIndex(for info: NSDraggingInfo) -> Int {
        let point = convert(info.draggingLocation, from: nil)
        let index = Int((point.y + tileHeight / 2) / (tileHeight + spacing))
        return min(max(0, index), tiles.count)
    }

    private func menu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Unpin Tab") { [weak self] in self?.onUnpin?(tab) })
        menu.addItem(ClosureMenuItem("Reset Pinned Tab") { [weak self] in self?.onClose?(tab) })
        menu.addItem(ClosureMenuItem("Copy Address") { tab.copyAddress() })
        return menu
    }
}

/// One pinned tile. The selected tile is tinted with the page's theme color.
@MainActor
final class PinnedTileView: NSView, NSDraggingSource {
    weak var tab: Tab?
    var onClick: (() -> Void)?
    private var mouseDownPoint: NSPoint?
    private let iconLayer = CALayer()
    private var isCurrent = false
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(isCurrent: Bool) {
        self.isCurrent = isCurrent
        iconLayer.contents = tab?.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        iconLayer.opacity = tab?.isAsleep == true && !isCurrent ? 0.75 : 1
        toolTip = tab?.displayTitle
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab?.displayTitle)
        updateColors()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.frame = NSRect(x: bounds.midX - 11, y: bounds.midY - 11, width: 22, height: 22)
        CATransaction.commit()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        if isCurrent {
            layer?.backgroundColor = resolved(Self.usableTint(tab?.themeColor) ?? SidebarColors.selected)
        } else {
            layer?.backgroundColor = resolved(isHovered ? SidebarColors.selected.withAlphaComponent(0.5) : SidebarColors.tile)
        }
        CATransaction.commit()
    }

    /// A theme color is used only when it has color and middle brightness. A near-black or
    /// near-white theme color would hide the icon (GitHub's dark theme, for example).
    private static func usableTint(_ color: NSColor?) -> NSColor? {
        guard let color = color?.usingColorSpace(.sRGB),
              color.saturationComponent > 0.25,
              (0.35...0.95).contains(color.brightnessComponent) else { return nil }
        return color.withAlphaComponent(0.85)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; updateColors() }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateColors() }
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if mouseDownPoint != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let tab,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        let item = NSPasteboardItem()
        item.setString(tab.id.uuidString, forType: .boskTab)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        dragItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
