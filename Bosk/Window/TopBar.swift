import AppKit

/// Back, forward, reload, and the page address. Click the address to edit it.
@MainActor
final class TopBar: NSView {
    var onAddressClick: (() -> Void)?

    /// Space on the left for the window buttons, when the sidebar does not hold them.
    var leadingInset: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    private let backButton = TopBar.makeButton("chevron.left", label: "Back", action: #selector(BrowserWindowController.browserBack(_:)))
    private let forwardButton = TopBar.makeButton("chevron.right", label: "Forward", action: #selector(BrowserWindowController.browserForward(_:)))
    private let reloadButton = TopBar.makeButton("arrow.clockwise", label: "Reload", action: #selector(BrowserWindowController.browserReload(_:)))
    private let addressField = NSTextField(labelWithString: "")
    private let progressLayer = CALayer()
    private let separator = CALayer()
    private(set) var accessoryViews: [NSView] = []
    private weak var tab: Tab?
    /// The menu's "Share" item does not keep its picker.
    private var sharePicker: NSSharingServicePicker?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for view in [backButton, forwardButton, reloadButton, addressField] { addSubview(view) }
        addressField.lineBreakMode = .byTruncatingTail
        addressField.font = .systemFont(ofSize: 13, weight: .medium)
        addressField.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(addressClicked)))
        addressField.menu = NSMenu()
        addressField.menu?.delegate = self
        progressLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        progressLayer.opacity = 0
        separator.backgroundColor = NSColor.separatorColor.cgColor
        layer?.addSublayer(separator)
        layer?.addSublayer(progressLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func makeButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
        let button = NSButton(image: image, target: nil, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        button.toolTip = label
        return button
    }

    /// Views on the right side, before the edge (extension buttons, "Add to Bosk").
    func setAccessoryViews(_ views: [NSView]) {
        accessoryViews.forEach { $0.removeFromSuperview() }
        accessoryViews = views
        views.forEach(addSubview)
        needsLayout = true
    }

    func update(with tab: Tab?) {
        self.tab = tab
        backButton.isEnabled = tab?.canGoBack ?? false
        forwardButton.isEnabled = tab?.canGoForward ?? false
        let loading = tab?.isLoading ?? false
        reloadButton.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise",
                                     accessibilityDescription: loading ? "Stop" : "Reload")
        reloadButton.action = loading ? #selector(BrowserWindowController.browserStop(_:))
                                      : #selector(BrowserWindowController.browserReload(_:))
        addressField.attributedStringValue = Self.addressText(for: tab)
        updateProgress(loading: loading, progress: tab?.estimatedProgress ?? 0)
    }

    /// "host / Page title": the host is strong, the title is dim.
    private static func addressText(for tab: Tab?) -> NSAttributedString {
        guard let tab, let url = tab.url else {
            return NSAttributedString(string: "Search or enter address",
                                      attributes: [.foregroundColor: NSColor.tertiaryLabelColor])
        }
        let host = url.host() ?? url.absoluteString
        let text = NSMutableAttributedString(string: host, attributes: [.foregroundColor: NSColor.labelColor])
        if !tab.title.isEmpty, tab.title != host {
            text.append(NSAttributedString(string: "  /  " + tab.title,
                                           attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        }
        return text
    }

    private func updateProgress(loading: Bool, progress: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        progressLayer.opacity = loading ? 1 : 0
        progressLayer.frame.size.width = bounds.width * (loading ? max(0.08, progress) : 1)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        var x = leadingInset + 10
        for button in [backButton, forwardButton, reloadButton] {
            button.frame = NSRect(x: x, y: midY - 14, width: 28, height: 28)
            x += 32
        }
        var right = bounds.maxX - 10
        // A hidden view (no downloads, no extensions) takes no space, so the last
        // visible button is as far from the right edge as Back is from the left edge.
        for view in accessoryViews.reversed() {
            let size = view.fittingSize
            guard size.width > 0 else { continue }
            right -= size.width
            view.frame = NSRect(x: right, y: midY - size.height / 2, width: size.width, height: size.height)
            right -= 6
        }
        addressField.frame = NSRect(x: x + 8, y: midY - 9, width: max(0, right - x - 16), height: 18)
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1 / (window?.backingScaleFactor ?? 2))
        progressLayer.frame = NSRect(x: 0, y: 0, width: progressLayer.frame.width, height: 2)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        progressLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        separator.backgroundColor = NSColor.separatorColor.cgColor
    }

    @objc private func addressClicked() { onAddressClick?() }
}

extension TopBar: NSMenuDelegate {
    /// The address's right-click menu, for the page shown now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let url = tab?.url else { return }
        menu.addItem(ClosureMenuItem("Copy Address") { [weak self] in self?.tab?.copyAddress() })
        if ["http", "https"].contains(url.scheme ?? "") {
            // Same action as Bookmarks > Bookmark This Page: it asks before it removes.
            let title = BookmarkStore.shared.bookmark(for: url) == nil ? "Add to Bookmarks" : "Remove Bookmark"
            menu.addItem(ClosureMenuItem(title) {
                NSApp.sendAction(#selector(BrowserWindowController.bookmarkPage(_:)), to: nil, from: nil)
            })
        }
        let picker = NSSharingServicePicker(items: [url])
        sharePicker = picker
        menu.addItem(picker.standardShareMenuItem)
    }
}
