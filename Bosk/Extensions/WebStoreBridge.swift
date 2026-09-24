import AppKit
import WebKit

/// Makes the Chrome Web Store's own "Add to Chrome" button install into Bosk.
/// The store enables the button only for a Chrome user agent and only when the page
/// has `chrome.webstorePrivate` and `chrome.management`. On the store host, Bosk sends a
/// Chrome user agent and adds those two APIs with a page script that calls Bosk.
/// The store scripts can change at any time; the "Add to Bosk" button is the fallback.
@MainActor
enum WebStoreBridge {
    static let host = "chromewebstore.google.com"
    static let messageName = "boskWebStore"

    /// The store checks that the user agent names are exactly "Mozilla AppleWebKit Chrome Safari".
    /// Keep the version below 142: from 142 the store can use a different check.
    private static let chromeVersion = "141.0.0.0"
    private static let chromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromeVersion) Safari/537.36"

    /// The custom user agent for a main frame navigation to this address (nil is WebKit's).
    static func userAgent(for url: URL?) -> String? {
        url?.host() == host ? chromeUserAgent : nil
    }

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addScriptMessageHandler(MessageHandler(), contentWorld: .page, name: messageName)
    }

    /// The subset of `chrome.webstorePrivate` and `chrome.management` that the store page uses.
    /// Errors go in `chrome.runtime.lastError` while the callback runs, as in Chrome.
    private static let script = """
        (() => {
          if (location.hostname !== '\(host)') return;
          const handler = window.webkit.messageHandlers.\(messageName);
          const chrome = window.chrome = window.chrome || {};
          chrome.runtime = chrome.runtime || {};
          const call = (callback, error, ...args) => {
            chrome.runtime.lastError = error ? { message: error } : undefined;
            try { callback && callback(...args); } finally { chrome.runtime.lastError = undefined; }
          };
          const event = () => {
            const listeners = new Set();
            return {
              addListener: (f) => listeners.add(f),
              removeListener: (f) => listeners.delete(f),
              hasListener: (f) => listeners.has(f),
              fire: (...args) => listeners.forEach((f) => f(...args)),
            };
          };
          const onInstalled = event(), onUninstalled = event();
          const send = (body) => handler.postMessage(body);
          chrome.webstorePrivate = {
            getExtensionStatus: (id, manifest, callback) => call(callback, null, 'installable'),
            isInIncognitoMode: (callback) => call(callback, null, false),
            getFullChromeVersion: (callback) => call(callback, null, { version_number: '\(chromeVersion)' }),
            beginInstallWithManifest3: (details, callback) => {
              send({ action: 'install', id: details.id }).then(
                (result) => call(callback, null, result),
                (error) => call(callback, String(error.message || error), 'unknown_error'));
            },
            completeInstall: (id, callback) => {
              call(callback, null);
              onInstalled.fire({ id });
            },
          };
          chrome.management = {
            getAll: (callback) => {
              send({ action: 'list' }).then(
                (ids) => call(callback, null, ids.map((id) => ({ id, enabled: true, installType: 'normal' }))),
                () => call(callback, null, []));
            },
            uninstall: (id, options, callback) => {
              send({ action: 'remove', id }).then(
                (removed) => {
                  call(callback, removed ? null : 'User cancelled uninstall');
                  if (removed) onUninstalled.fire(id);
                },
                (error) => call(callback, String(error.message || error)));
            },
            onInstalled, onUninstalled,
          };
        })();
        """

    /// Receives calls from the store page. Only the store's main frame may call, because
    /// the handler is in the page world, where any site's script could post to it.
    private final class MessageHandler: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == host,
                  message.frameInfo.securityOrigin.protocol == "https",
                  let body = message.body as? [String: Any], let action = body["action"] as? String else {
                return (nil, "Not allowed")
            }
            let manager = ExtensionManager.shared
            let id = body["id"] as? String ?? ""
            let window = message.webView?.window
            switch action {
            case "list":
                return (manager.records.map(\.id), nil)
            case "install":
                do {
                    try await manager.installFromWebStore(extensionID: id, in: window)
                } catch {
                    return (nil, error.localizedDescription)
                }
                // installFromWebStore returns without an error when the user says no.
                return (manager.records.contains { $0.id == id } ? "success" : "user_cancelled", nil)
            case "remove":
                guard manager.records.contains(where: { $0.id == id }) else { return (true, nil) }
                // A disabled extension has no context, so it has no name here.
                let name = manager.contexts[id]?.webExtension.displayName ?? "this extension"
                guard await ExtensionPrompts.confirm(
                    title: "Remove \u{201C}\(name)\u{201D}?",
                    message: "Bosk deletes the extension and its files. You can add it again later.",
                    confirmTitle: "Remove", in: window) else { return (false, nil) }
                manager.remove(id: id)
                return (true, nil)
            default:
                return (nil, "Unknown action")
            }
        }
    }
}
