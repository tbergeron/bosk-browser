import AppKit
import WebKit

/// Shows the selected tab's web view. Only one web view is in the window at a time,
/// so WebKit treats the other tabs as hidden and slows their timers.
@MainActor
final class WebContainerView: NSView {
    private(set) var webView: WKWebView?
    private var pageView: NSView?
    private let snapshotView = NSImageView()
    /// The link under the mouse, at the bottom left, like Safari's status bar.
    private let statusBox = NSBox()
    private let statusLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.autoresizingMask = [.width, .height]
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusBox.boxType = .custom
        statusBox.fillColor = .windowBackgroundColor
        statusBox.borderColor = .separatorColor
        statusBox.cornerRadius = 5
        statusBox.contentViewMargins = NSSize(width: 6, height: 2)
        statusBox.contentView = statusLabel
        statusBox.isHidden = true
        addSubview(statusBox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ webView: WKWebView?) {
        guard webView !== self.webView else { return }
        // Not the web view's superview: a tab that sleeps removes its web view first.
        pageView?.removeFromSuperview()
        self.webView = webView
        pageView = webView.map(Self.pageView)
        guard let pageView else { return }
        pageView.frame = bounds
        addSubview(pageView, positioned: .below, relativeTo: snapshotView.superview == nil ? nil : snapshotView)
    }

    private static var pageViewKey = 0

    /// Each web view has its own superview. WebKit puts a docked Web Inspector in the web view's
    /// superview, so the inspector goes away and comes back with its tab. The web view keeps this
    /// view; Tab removes the web view from it when the tab closes or sleeps, and then both can go.
    private static func pageView(for webView: WKWebView) -> NSView {
        if let pageView = objc_getAssociatedObject(webView, &pageViewKey) as? NSView, webView.superview === pageView {
            return pageView
        }
        let pageView = NSView()
        pageView.autoresizingMask = [.width, .height]
        webView.frame = pageView.bounds
        webView.autoresizingMask = [.width, .height]
        pageView.addSubview(webView)
        objc_setAssociatedObject(webView, &pageViewKey, pageView, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return pageView
    }

    /// Covers the web view with a picture of the page until the page draws.
    func showSnapshot(_ image: NSImage?) {
        guard let image else { return hideSnapshot() }
        snapshotView.image = image
        snapshotView.frame = bounds
        if snapshotView.superview == nil { addSubview(snapshotView) }
    }

    func hideSnapshot() {
        snapshotView.removeFromSuperview()
        snapshotView.image = nil
    }

    /// - Parameter text: nil hides the bubble.
    func showStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusBox.isHidden = text == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = statusLabel.intrinsicContentSize
        let margins = statusBox.contentViewMargins
        // Not flipped: y = 0 is the bottom. Inset from the card's round corner.
        statusBox.frame = NSRect(x: 4, y: 4, width: min(size.width + margins.width * 2 + 2, bounds.width * 0.6),
                                 height: size.height + margins.height * 2 + 2)
    }

    /// The status bubble takes no clicks: they go to the page under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view?.isDescendant(of: statusBox) == true ? webView : view
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}
