import AppKit
import WebKit

/// Shows the selected tab's web view. Only one web view is in the window at a time,
/// so WebKit treats the other tabs as hidden and slows their timers.
@MainActor
final class WebContainerView: NSView {
    private(set) var webView: WKWebView?
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
        self.webView?.removeFromSuperview()
        self.webView = webView
        guard let webView else { return }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView, positioned: .below, relativeTo: snapshotView.superview == nil ? nil : snapshotView)
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
