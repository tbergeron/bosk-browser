import AppKit
import WebKit

/// WKWebView with Bosk's context menu: "New Window" items open tabs, and the page menu
/// has Show Reader.
final class BoskWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            // WebKit opens these through createWebViewWith, which makes a new tab in Bosk.
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow": item.title = "Open Link in New Tab"
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = "Open Image in New Tab"
            case "WKMenuItemIdentifierOpenMediaInNewWindow": item.title = "Open Video in New Tab"
            case "WKMenuItemIdentifierOpenFrameInNewWindow": item.title = "Open Frame in New Tab"
            default: break
            }
        }
        // Show Reader goes in the page's own menu (it has Reload), not in link or image menus.
        if let tab = WebViewFactory.tab(for: self),
           let reload = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" }),
           let reader = ReaderMode.menuItem(for: tab) {
            menu.insertItem(reader, at: reload + 1)
        }
        // Extension items: WebKit adds them itself, with the clicked image or link.
    }
}

/// WebKit's Web Inspector (the developer tools) for a page. WebKit has no public API to open it,
/// so this uses the private `_inspector`, as Safari does. A macOS update can remove it: then
/// View > Show Web Inspector is disabled.
@MainActor
enum WebInspector {
    private static let inspectorSelector = NSSelectorFromString("_inspector")

    private static func inspector(of webView: WKWebView) -> NSObject? {
        guard webView.responds(to: inspectorSelector) else { return nil }
        return webView.perform(inspectorSelector)?.takeUnretainedValue() as? NSObject
    }

    static func isAvailable(for webView: WKWebView) -> Bool {
        inspector(of: webView)?.responds(to: NSSelectorFromString("show")) == true
    }

    static func isVisible(in webView: WKWebView) -> Bool {
        guard let inspector = inspector(of: webView), inspector.responds(to: NSSelectorFromString("isVisible")) else {
            return false
        }
        return inspector.value(forKey: "isVisible") as? Bool ?? false
    }

    /// Shows the inspector, or closes it if it is open.
    static func toggle(in webView: WKWebView) {
        guard let inspector = inspector(of: webView) else { return }
        let selector = NSSelectorFromString(isVisible(in: webView) ? "close" : "show")
        guard inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }
}

/// In Dark Mode, a new web view shows the dark window color, not white, until its first page has
/// content: a cover view is over it until then. WebKit has no public event for the first content, so this
/// uses the private rendering progress events. Without them, there is no cover, and the view is white as before.
@MainActor
enum PageBackground {
    /// `_WKRenderingProgressEventFirstVisuallyNonEmptyLayout`. It comes when the page has text or
    /// images, after its style sheets load. The first layout (1 << 0) comes before the page has content.
    static let firstVisuallyNonEmptyLayout: UInt = 1 << 1

    static func hideUntilFirstContent(in webView: WKWebView) {
        guard NSApp.effectiveAppearance.isDark,
              webView.responds(to: NSSelectorFromString("_setObservedRenderingProgressEvents:")) else { return }
        webView.setValue(firstVisuallyNonEmptyLayout, forKey: "observedRenderingProgressEvents")
        let cover = CoverView(frame: webView.bounds)
        cover.autoresizingMask = [.width, .height]
        webView.addSubview(cover)
    }

    /// At the first content, and at the latest when the page loads (a page with little content).
    static func show(in webView: WKWebView) {
        webView.subviews.first { $0 is CoverView }?.removeFromSuperview()
    }

    private final class CoverView: NSView {
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    }
}
