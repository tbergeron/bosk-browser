import WebKit

/// Makes every web view in Bosk. All tabs share one data store, one user content
/// controller and (later) one extension controller, so they share cookies and scripts.
@MainActor
enum WebViewFactory {
    static let userContentController: WKUserContentController = {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: unsentInputScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false))
        controller.add(ScriptMessageRouter(), name: unsentInputMessage)
        return controller
    }()

    static let unsentInputMessage = "boskUnsentInput"

    /// Tells Bosk when the user types in a form (true) and when the form is sent (false).
    /// Tab sleep does not sleep a tab with unsent text, because the reload would delete it.
    private static let unsentInputScript = """
        (() => {
          let dirty = false;
          const report = (value) => {
            if (dirty === value) return;
            dirty = value;
            window.webkit.messageHandlers.\(unsentInputMessage).postMessage(value);
          };
          const isField = (el) => el && (el.isContentEditable || el.tagName === 'TEXTAREA' ||
            (el.tagName === 'INPUT' && !['button', 'checkbox', 'radio', 'submit', 'range', 'color'].includes(el.type)));
          document.addEventListener('input', (e) => { if (isField(e.target)) report(true); }, true);
          document.addEventListener('submit', () => report(false), true);
        })();
        """

    /// Finds the tab that owns a web view, for page script messages.
    private static let owners = NSMapTable<WKWebView, Tab>.weakToWeakObjects()

    static func register(_ webView: WKWebView, for tab: Tab) {
        owners.setObject(tab, forKey: webView)
    }

    static func tab(for webView: WKWebView?) -> Tab? {
        webView.flatMap { owners.object(forKey: $0) }
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = userContentController
        configuration.applicationNameForUserAgent = Defaults.userAgentApplicationName
        configuration.preferences.isElementFullscreenEnabled = true
        // Content scripts of extensions run only in web views with this controller.
        configuration.webExtensionController = ExtensionManager.shared.controller
        return configuration
    }

    /// - Parameter configuration: Pass WebKit's configuration for pop-ups
    ///   (`createWebViewWith`); nil makes a new one.
    static func makeWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let webView = BoskWebView(frame: .zero, configuration: configuration ?? makeConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
    }
}

/// Receives page script messages and gives them to the tab. The user content controller
/// keeps a strong reference to its handlers, so this object holds no tab references.
private final class ScriptMessageRouter: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.name == WebViewFactory.unsentInputMessage,
                  let tab = WebViewFactory.tab(for: message.webView) else { return }
            tab.hasUnsentInput = message.body as? Bool ?? false
        }
    }
}
