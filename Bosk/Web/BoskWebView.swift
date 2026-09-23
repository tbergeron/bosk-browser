import AppKit
import WebKit

/// WKWebView with Bosk's context menu: "New Window" items open tabs.
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
        if let tab = WebViewFactory.tab(for: self) {
            let extensionItems = ExtensionManager.shared.loadedContexts.flatMap { $0.menuItems(for: tab) }
            if !extensionItems.isEmpty {
                menu.addItem(.separator())
                extensionItems.forEach(menu.addItem)
            }
        }
    }
}
