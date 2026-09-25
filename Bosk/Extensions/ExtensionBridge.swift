import AppKit
import BoskCore
import WebKit

// WebKit asks Bosk about tabs, windows and permissions through these conformances.
// A sleeping tab has no web view; WebKit still gets its URL and title.

extension ExtensionManager: WKWebExtensionControllerDelegate {
    var focusedWindowController: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? BrowserWindowController)
            ?? windowsProvider?().first
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        windowsProvider?() ?? []
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        focusedWindowController
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let window = (configuration.window as? BrowserWindowController) ?? focusedWindowController else {
            return completionHandler(nil, nil)
        }
        let tab = window.store.newTab(url: configuration.url, select: configuration.shouldBeActive)
        if configuration.shouldBePinned { window.store.pin(tab) }
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return completionHandler(nil, nil) }
        let window = appDelegate.openWindow(showCommandBar: false)
        for url in configuration.tabURLs { window.store.newTab(url: url) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL { focusedWindowController?.store.newTab(url: url) }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        ask(extensionContext, PermissionText.summary(permissions: permissions, patterns: [])) { allowed in
            completionHandler(allowed ? permissions : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = PermissionText.list(Set(urls.map { $0.host() ?? $0.absoluteString }).sorted())
        ask(extensionContext, "It can:\n• Read and change data on: \(hosts)") { allowed in
            completionHandler(allowed ? urls : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        ask(extensionContext, PermissionText.summary(permissions: [], patterns: matchPatterns)) { allowed in
            completionHandler(allowed ? matchPatterns : [], nil)
        }
    }

    /// One question per request. The answer is saved, so it is asked once.
    private func ask(_ context: WKWebExtensionContext, _ message: String, answer: @escaping (Bool) -> Void) {
        let name = context.webExtension.displayName ?? "An extension"
        let window = focusedWindowController?.window
        Task {
            let allowed = await ExtensionPrompts.confirm(title: "“\(name)” asks for more access",
                                                         message: message, confirmTitle: "Allow", in: window)
            answer(allowed)
            // WebKit applies the answer after the completion handler; save on the next turn.
            DispatchQueue.main.async { ExtensionManager.shared.saveRegistry() }
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        // Each window shows the badge for its own tab.
        windowsProvider?().forEach { $0.extensionActionsChanged(for: context) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        focusedWindowController?.presentPopup(for: action, of: context)
        completionHandler(nil)
    }

    /// `runtime.sendNativeMessage`. To "bosk": the Chrome APIs WebKit does not have, answered by
    /// Bosk (ExtensionShimAnswers). To another name: a Chrome native messaging host on this Mac.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any,
                                toApplicationWithIdentifier applicationIdentifier: String?,
                                for context: WKWebExtensionContext,
                                replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        guard let host = applicationIdentifier, host != ExtensionShim.application else {
            Task { replyHandler(await ExtensionShimAnswers.answer(message, from: context), nil) }
            return
        }
        let id = context.uniqueIdentifier
        // JSON values that WebKit made for this call only; nothing else holds them.
        nonisolated(unsafe) let message = message
        Task {
            do {
                replyHandler(try await ExtensionNative.send(message, to: host, from: id), nil)
            } catch {
                // An extension that asks a missing app in a loop (Bitwarden's "sleep") gets its
                // answer slowly after a dozen tries in a second, so it cannot flood Bosk.
                let key = id + "→" + host, now = Date()
                nativeFailures[key] = (nativeFailures[key] ?? []).filter { now.timeIntervalSince($0) < 1 } + [now]
                if (nativeFailures[key]?.count ?? 0) > 12 { try? await Task.sleep(for: .seconds(1)) }
                replyHandler(nil, error)
            }
        }
    }

    /// `runtime.connectNative`: a worker's WebSocket (ExtensionSocket), or a native messaging host.
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        #if DEBUG
        NSLog("Bosk: native port %@ from %@", port.applicationIdentifier ?? "?", context.uniqueIdentifier)
        #endif
        switch port.applicationIdentifier {
        case ExtensionShim.socketApplication:
            ExtensionSocket.connect(port, from: context.uniqueIdentifier)
            completionHandler(nil)
        case ExtensionShim.application:
            // The port a worker's shim opens only to find what all ports share; it closes at once.
            completionHandler(nil)
        case ExtensionShim.aliveApplication:
            watchWorker(port, of: context)
            completionHandler(nil)
        default:
            do {
                try ExtensionNative.connect(port, from: context.uniqueIdentifier)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

extension Tab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        store?.windowController
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        store?.allTabs.firstIndex { $0 === self } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { title }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned }
    func isSelected(for context: WKWebExtensionContext) -> Bool { store?.selectedTab === self }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        // The media check in TabSleepManager is async; an extension asks synchronously.
        // "Not playing" is the safe answer for a sleeping tab.
        false
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        store?.select(self)
        store?.window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext,
                     completionHandler: @escaping ((any Error)?) -> Void) {
        if selected { store?.select(self) }
        completionHandler(nil)
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any Error)?) -> Void) {
        if pinned, !isPinned { store?.pin(self) } else if !pinned, isPinned { store?.unpin(self) }
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext,
                completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goForward()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        store?.close(self)
        completionHandler(nil)
    }
}

extension BrowserWindowController: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { store.allTabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { store.selectedTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }
}
