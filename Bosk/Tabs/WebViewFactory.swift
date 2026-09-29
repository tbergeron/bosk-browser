import BoskCore
import WebKit

/// Makes every web view in Bosk. Normal tabs share the default data store, one user content
/// controller and the extension controller, so they share cookies and scripts. Private tabs
/// share the private data store (in memory only) and their own user content controller, with no extensions.
@MainActor
enum WebViewFactory {
    static let userContentController: WKUserContentController = makeUserContentController(isPrivate: false)
    /// For private tabs. WebKit puts the content scripts of extensions on the user content controller
    /// of each web view with the extension controller, so with one shared controller they ran in private tabs too.
    static let privateUserContentController: WKUserContentController = makeUserContentController(isPrivate: true)
    /// Both controllers. The built-in blockers put their rule lists on each.
    static var userContentControllers: [WKUserContentController] { [userContentController, privateUserContentController] }

    private static func makeUserContentController(isPrivate: Bool) -> WKUserContentController {
        let controller = WKUserContentController()
        // A separate world, so page scripts cannot send the message and keep the tab awake.
        controller.addUserScript(WKUserScript(source: unsentInputScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false, in: scriptWorld))
        controller.add(ScriptMessageRouter(), contentWorld: scriptWorld, name: unsentInputMessage)
        // Extensions are off in private windows, so the Web Store cannot install from them.
        if !isPrivate { WebStoreBridge.install(in: controller) }
        return controller
    }

    static let unsentInputMessage = "boskUnsentInput"
    static let scriptWorld = WKContentWorld.world(name: "Bosk")

    /// Tells Bosk, for each frame, when the user types in a form (dirty: true) and when that
    /// text is gone (dirty: false). Tab sleep does not sleep a tab with unsent text, because
    /// the reload would delete it. Chat and mail apps clear their fields with script and send
    /// no `submit`, so the fields are checked again when the page goes to the background.
    private static let unsentInputScript = """
        (() => {
          const frame = Math.random().toString(36).slice(2);
          const edited = new Set();
          let dirty = false;
          const report = (value) => {
            if (dirty === value) return;
            dirty = value;
            window.webkit.messageHandlers.\(unsentInputMessage).postMessage({ frame, dirty: value });
          };
          const isField = (el) => el && (el.isContentEditable || el.tagName === 'TEXTAREA' ||
            (el.tagName === 'INPUT' && !['button', 'checkbox', 'radio', 'submit', 'range', 'color'].includes(el.type)));
          const hasText = (el) => el.isConnected &&
            (el.isContentEditable ? el.textContent.trim() !== '' : el.value.trim() !== '' && el.value !== el.defaultValue);
          const check = () => {
            for (const el of edited) if (!hasText(el)) edited.delete(el);
            report(edited.size > 0);
          };
          document.addEventListener('input', (e) => { if (isField(e.target)) { edited.add(e.target); report(true); } }, true);
          document.addEventListener('submit', (e) => {
            for (const el of edited) if (e.target.contains(el)) edited.delete(el);
            check();
          }, true);
          document.addEventListener('visibilitychange', () => { if (document.hidden) check(); });
          window.addEventListener('pagehide', () => report(false));
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

    /// - Parameter privateStore: The data store of the private windows; nil for a normal tab.
    static func makeConfiguration(privateStore: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = privateStore ?? .default()
        configuration.userContentController = privateStore == nil ? userContentController : privateUserContentController
        configuration.applicationNameForUserAgent = Defaults.userAgentApplicationName
        configuration.setURLSchemeHandler(ReaderMode.schemeHandler, forURLScheme: ReaderPage.scheme)
        configuration.preferences.isElementFullscreenEnabled = true
        // Private, as in Safari's Develop menu: the Web Inspector opens only with this on.
        // It also adds Inspect Element to the page's menu.
        if configuration.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        // Content scripts of extensions run only in web views with this controller.
        // Private tabs have none: extensions are off in private windows.
        if privateStore == nil { configuration.webExtensionController = ExtensionManager.shared.controller }
        return configuration
    }

    /// - Parameters:
    ///   - configuration: Pass WebKit's configuration for pop-ups (`createWebViewWith`),
    ///     which has the opener's data store; nil makes a new one.
    ///   - privateStore: For a new configuration: the data store of the private windows; nil for a normal tab.
    static func makeWebView(configuration: WKWebViewConfiguration? = nil,
                            privateStore: WKWebsiteDataStore? = nil) -> WKWebView {
        let webView = BoskWebView(frame: .zero, configuration: configuration ?? makeConfiguration(privateStore: privateStore))
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        PageBackground.hideUntilFirstContent(in: webView)
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
            guard let body = message.body as? [String: Any], let frame = body["frame"] as? String else { return }
            if body["dirty"] as? Bool == true {
                tab.framesWithUnsentInput.insert(frame)
            } else {
                tab.framesWithUnsentInput.remove(frame)
            }
        }
    }
}
