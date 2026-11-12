import AppKit
import WebKit

/// WKWebView with Bosk's context menu: "New Window" items open tabs, and the page menu
/// has Show Reader.
final class BoskWebView: WKWebView {
    /// Set by the page menu's "Open … in New Tab" items. createWebViewWith reads it (and clears it)
    /// and does not select that tab. The navigation action does not tell a menu item from a click.
    var opensBackgroundTab = false
    /// WebKit's own target and action for those items. All of them use the same pair.
    private var menuTarget: AnyObject?
    private var menuAction: Selector?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // "Open Link" does the same as a click on the link.
        menu.items.removeAll { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }
        for item in menu.items {
            // WebKit opens these through createWebViewWith, which makes a new tab in Bosk.
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow": item.title = "Open Link in New Tab"
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = "Open Image in New Tab"
            case "WKMenuItemIdentifierOpenMediaInNewWindow": item.title = "Open Video in New Tab"
            case "WKMenuItemIdentifierOpenFrameInNewWindow": item.title = "Open Frame in New Tab"
            default: continue
            }
            menuTarget = item.target
            menuAction = item.action
            item.target = self
            item.action = #selector(openInBackgroundTab(_:))
        }
        // Show Reader goes in the page's own menu (it has Reload), not in link or image menus.
        if let tab = WebViewFactory.tab(for: self),
           let reload = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" }),
           let reader = ReaderMode.menuItem(for: tab) {
            menu.insertItem(reader, at: reload + 1)
        }
        // Extension items: WebKit adds them itself, with the clicked image or link.
    }

    /// Marks the next new tab as a background tab, then lets WebKit do the item's work.
    @objc private func openInBackgroundTab(_ sender: NSMenuItem) {
        guard let menuAction else { return }
        opensBackgroundTab = true
        NSApp.sendAction(menuAction, to: menuTarget, from: sender)
    }

    /// A tab switch, sleep or close takes the web view out of the window. If a password field has
    /// focus then, WebKit does not turn Secure Keyboard Entry off, and it stays on until Bosk quits.
    /// Blur first, so WebKit turns it off.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, newWindow !== window, (window.firstResponder as? NSView)?.isDescendant(of: self) == true {
            window.makeFirstResponder(nil)
        }
        super.viewWillMove(toWindow: newWindow)
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

/// WebKit has no public event for a page's first content, so this uses the private rendering progress
/// events. Two covers use them: in Dark Mode a cover view keeps a new web view at the dark window color,
/// not white, until its first page has content; and a woken tab keeps its picture until the page draws.
/// Without the private events there is no cover, and the view is white as before.
@MainActor
enum PageBackground {
    /// `_WKRenderingProgressEventFirstVisuallyNonEmptyLayout`. It comes when the page has text or
    /// images, after its style sheets load. The first layout (1 << 0) comes before the page has content.
    static let firstVisuallyNonEmptyLayout: UInt = 1 << 1

    static func watchFirstContent(in webView: WKWebView) {
        guard webView.responds(to: NSSelectorFromString("_setObservedRenderingProgressEvents:")) else { return }
        webView.setValue(firstVisuallyNonEmptyLayout, forKey: "observedRenderingProgressEvents")
        guard NSApp.effectiveAppearance.isDark else { return }
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
