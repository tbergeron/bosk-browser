import AppKit
import WebKit

/// Shows the selected tab's web view. Only one web view is in the window at a time,
/// so WebKit treats the other tabs as hidden and slows their timers.
@MainActor
final class WebContainerView: NSView {
    private(set) var webView: WKWebView?
    private let snapshotView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.autoresizingMask = [.width, .height]
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

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}
