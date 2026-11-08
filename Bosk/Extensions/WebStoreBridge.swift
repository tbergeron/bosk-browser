import AppKit
import WebKit

/// Makes the Chrome Web Store's own "Add to Chrome" button install into Bosk.
/// The store enables the button only for a Chrome user agent and only when the page
/// has `chrome.webstorePrivate` and `chrome.management`. On the store host, a page script
/// gives `navigator` a Chrome user agent and adds those two APIs, which call Bosk.
/// The script does not set the web view's user agent: when a page loads with another user
/// agent, WebKit stops the extension workers and does not start them again (found by Search).
/// The message handler is in Bosk's script world, and a relay script there carries the calls.
/// A handler in the page world gives each site a `window.webkit`, which real Safari does not
/// have: sites use it to detect an embedded browser.
/// The store scripts can change at any time; the "Add to Bosk" button is the fallback.
@MainActor
enum WebStoreBridge {
    static let host = "chromewebstore.google.com"
    static let messageName = "boskWebStore"
    private static let callEvent = "boskWebStoreCall"
    private static let replyEvent = "boskWebStoreReply"

    /// The store checks that the user agent names are exactly "Mozilla AppleWebKit Chrome Safari".
    /// Keep the version below 142: from 142 the store can use a different check.
    static let chromeVersion = "141.0.0.0"
    private static let chromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromeVersion) Safari/537.36"

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: relayScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: WebViewFactory.scriptWorld))
        controller.addScriptMessageHandler(MessageHandler(), contentWorld: WebViewFactory.scriptWorld, name: messageName)
    }

    /// Carries the page script's calls to Bosk and the answers back. The two scripts are in
    /// different worlds, so they share only the DOM: JSON text in events on the document.
    private static let relayScript = """
        (() => {
          if (location.hostname !== '\(host)') return;
          const handler = window.webkit.messageHandlers.\(messageName);
          document.addEventListener('\(callEvent)', (e) => {
            const { id, body } = JSON.parse(e.detail);
            const reply = (answer) => document.dispatchEvent(
              new CustomEvent('\(replyEvent)', { detail: JSON.stringify({ id, ...answer }) }));
            handler.postMessage(body).then(
              (result) => reply({ result }),
              (error) => reply({ error: String(error.message || error) }));
          });
        })();
        """

    /// The subset of `chrome.webstorePrivate` and `chrome.management` that the store page uses.
    /// Errors go in `chrome.runtime.lastError` while the callback runs, as in Chrome.
    private static let script = """
        (() => {
          if (location.hostname !== '\(host)') return;
          const userAgent = '\(chromeUserAgent)';
          for (const [key, value] of [['userAgent', userAgent], ['appVersion', userAgent.replace(/^Mozilla\\//, '')],
                                      ['vendor', 'Google Inc.']]) {
            Object.defineProperty(Navigator.prototype, key, { get: () => value, configurable: true });
          }
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
          let lastCall = 0;
          const pending = new Map();
          document.addEventListener('\(replyEvent)', (e) => {
            const { id, result, error } = JSON.parse(e.detail);
            const promise = pending.get(id);
            pending.delete(id);
            if (error === undefined) promise.resolve(result); else promise.reject(error);
          });
          const send = (body) => new Promise((resolve, reject) => {
            const id = ++lastCall;
            pending.set(id, { resolve, reject });
            document.dispatchEvent(new CustomEvent('\(callEvent)', { detail: JSON.stringify({ id, body }) }));
          });
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

    /// Receives calls from the store page, through the relay. Only the store's main frame may call.
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
