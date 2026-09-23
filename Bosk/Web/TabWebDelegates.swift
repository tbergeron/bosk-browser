import AppKit
import WebKit

// WebKit delegates for a tab: navigation policy, downloads, sign-in prompts, errors,
// page dialogs, file uploads, and camera and microphone permission.

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        // Cmd-click (or middle-click) on a link: open it in a background tab below this one.
        let isNewTabClick = navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2
        if navigationAction.navigationType == .linkActivated, isNewTabClick, let url = navigationAction.request.url {
            let tab = Tab(url: url)
            tab.favicon = FaviconStore.shared.cachedIcon(for: url)
            store?.insert(tab, after: self, select: navigationAction.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .allow }
        // "Content-Disposition: attachment" means "save this", even for types WebKit can show.
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if disposition.hasPrefix("attachment") || !navigationResponse.canShowMIMEType { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
        // A tab that opened only for this download has no page: close it.
        if webView.backForwardList.currentItem == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.store?.close(self)
            }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasUnsentInput = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, url == errorPageURL {
            errorPageURL = nil
            return
        }
        FaviconStore.shared.refresh(for: self)
        if let url = webView.url {
            let title = webView.title ?? title
            Task { await HistoryStore.shared.recordVisit(url: url, title: title) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        showErrorPage(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        showErrorPage(error, in: webView)
    }

    /// The page's process crashed or was killed. Load the page again instead of a blank tab.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
               NSURLAuthenticationMethodNTLM].contains(method),
              let window = store?.window else { return (.performDefaultHandling, nil) }
        guard let (user, password) = await PageDialogs.signIn(host: challenge.protectionSpace.host, in: window) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
    }

    private func showErrorPage(_ error: any Error, in webView: WKWebView) {
        let error = error as NSError
        // Cancelled loads (a new navigation started) and "frame load interrupted" (downloads) are not errors.
        guard error.code != NSURLErrorCancelled, !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }
        let failedURL = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        errorPageURL = failedURL
        webView.loadHTMLString(PageDialogs.errorPage(message: error.localizedDescription, url: failedURL),
                               baseURL: failedURL)
    }
}

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // window.open and target=_blank: WebKit loads the request into the web view we return.
        let popup = WebViewFactory.makeWebView(configuration: configuration)
        let tab = Tab(adopting: popup)
        tab.opener = self
        store?.insert(tab, after: self, select: true)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        store?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        guard let window = store?.window else { return }
        await PageDialogs.alert(message, host: frame.securityOrigin.host, in: window)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard let window = store?.window else { return false }
        return await PageDialogs.confirm(message, host: frame.securityOrigin.host, in: window)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard let window = store?.window else { return nil }
        return await PageDialogs.prompt(prompt, defaultText: defaultText, host: frame.securityOrigin.host, in: window)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let window = store?.window else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard let window = store?.window else { return .deny }
        return await PermissionMemory.shared.decision(for: origin.host, type: type) {
            await PageDialogs.confirm(PermissionMemory.question(host: origin.host, type: type),
                                      host: nil, in: window, confirmTitle: "Allow", cancelTitle: "Don’t Allow")
        }
    }
}

/// Camera and microphone answers, per site, until Bosk quits. Not saved to disk:
/// a site gets camera access again only after the user says yes again.
@MainActor
final class PermissionMemory {
    static let shared = PermissionMemory()
    private var answers: [String: Bool] = [:]

    func decision(for host: String, type: WKMediaCaptureType,
                  ask: () async -> Bool) async -> WKPermissionDecision {
        let key = "\(host)|\(type.rawValue)"
        if let answer = answers[key] { return answer ? .grant : .deny }
        let answer = await ask()
        answers[key] = answer
        return answer ? .grant : .deny
    }

    static func question(host: String, type: WKMediaCaptureType) -> String {
        let device = switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        case .cameraAndMicrophone: "camera and microphone"
        @unknown default: "camera or microphone"
        }
        return "Allow “\(host)” to use your \(device)?"
    }
}
