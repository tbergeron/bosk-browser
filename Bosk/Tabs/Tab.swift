import AppKit
import WebKit

/// One tab. When `webView` is nil the tab is asleep: it keeps its URL, title,
/// favicon and saved session state, but it has no web process.
@MainActor
final class Tab: NSObject {
    enum Change {
        /// `progress` is only `estimatedProgress`; it changes many times for each load.
        case title, url, favicon, themeColor, loading, progress, navigationState, sleepState, hoveredLink
    }

    let id: UUID
    /// Set when this tab is this window's copy of a pinned entry.
    var pinnedEntryID: UUID?
    var isPinned: Bool { pinnedEntryID != nil }

    private(set) var url: URL?
    private(set) var title: String
    var favicon: NSImage? {
        didSet { notify(.favicon) }
    }
    /// The page's `<meta name="theme-color">`, used to tint its pinned tile.
    private(set) var themeColor: NSColor?
    /// The last time the user looked at this tab. Tab sleep uses it.
    var lastActive = Date()
    /// WebKit's saved back/forward list and scroll positions (`interactionState`).
    private(set) var sessionState: Data?
    /// A small JPEG of the page, taken when the user leaves the tab. It is shown while a
    /// sleeping tab wakes up. JPEG data, not an image, so sleeping tabs stay small in memory.
    private(set) var snapshotData: Data?
    /// The frames with text typed in a form and not sent yet. Set by a page script.
    var framesWithUnsentInput: Set<String> = []
    /// Tab sleep checks it.
    var hasUnsentInput: Bool { !framesWithUnsentInput.isEmpty }
    /// When the page's process last stopped and the page loaded again (last minute only).
    var crashReloads: [Date] = []
    /// The address of the Bosk error page on screen, so it does not go into history.
    var errorPageURL: URL?
    /// The link under the mouse, for the status bubble. WebKit sets it on each mouse move.
    var hoveredLink: URL? {
        didSet { if hoveredLink != oldValue { notify(.hoveredLink) } }
    }

    /// This tab's zoom when the user changed it with Cmd+= / Cmd+-; nil follows the default.
    var zoomOverride: Double? {
        didSet { webView?.pageZoom = zoomOverride ?? PageZoom.defaultZoom }
    }

    /// The tab whose page opened this one (window.open, target=_blank). When this tab closes
    /// while on screen, the user goes back to that page.
    weak var opener: Tab?

    private(set) var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    weak var store: TabStore?

    var isAsleep: Bool { webView == nil }
    var isLoading: Bool { webView?.isLoading ?? false }
    var estimatedProgress: Double { webView?.estimatedProgress ?? 0 }
    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }
    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? "New Tab"
    }

    init(id: UUID = UUID(), url: URL?, title: String = "", sessionState: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.sessionState = sessionState
        super.init()
    }

    /// A tab for a pop-up. WebKit made the web view and will load it.
    init(adopting webView: WKWebView) {
        id = UUID()
        url = nil
        title = ""
        super.init()
        attach(webView)
    }

    // MARK: Loading

    func load(_ url: URL) {
        let webView = webView ?? wake(loadSavedState: false)
        webView.load(URLRequest(url: url))
        self.url = url
        notify(.url)
    }

    /// Makes the web view. It restores the saved session state (the page reloads),
    /// or loads the last URL.
    @discardableResult
    func wake(loadSavedState: Bool = true) -> WKWebView {
        if let webView { return webView }
        let webView = WebViewFactory.makeWebView()
        attach(webView)
        if loadSavedState {
            if let sessionState {
                webView.interactionState = sessionState as NSData
            } else if let url {
                webView.load(URLRequest(url: url))
            }
        }
        notify(.sleepState)
        return webView
    }

    /// Removes the web view so WebKit can end its web process.
    func sleep() {
        guard let webView else { return }
        saveSessionState()
        detach(webView)
        notify(.sleepState)
    }

    /// Goes back to `url` and sleeps (a closed pinned tab).
    func reset(to url: URL, title: String) {
        if let webView { detach(webView) }
        self.url = url
        self.title = title
        sessionState = nil
        snapshotData = nil
        favicon = FaviconStore.shared.cachedIcon(for: url)
        notify(.url)
        notify(.sleepState)
    }

    func saveSessionState() {
        if let state = webView?.interactionState as? Data { sessionState = state }
    }

    // MARK: Web view

    /// Saves a picture of the page for the next wake. Call before the tab leaves the screen.
    func captureSnapshot() {
        guard let webView, webView.window != nil, !webView.bounds.isEmpty else { return }
        let configuration = WKSnapshotConfiguration()
        // WebKit takes the width in points and makes 2 pixels per point on Retina screens.
        // The picture shows for about a second, so 1x is enough, at a quarter of the memory.
        let scale = webView.window?.backingScaleFactor ?? 1
        configuration.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, Defaults.snapshotWidth) / scale))
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            Task.detached(priority: .utility) {
                let data = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.6])
                await MainActor.run { self?.snapshotData = data }
            }
        }
    }

    private func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.pageZoom = zoomOverride ?? PageZoom.defaultZoom
        WebViewFactory.register(webView, for: self)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let title = webView.title, !title.isEmpty else { return }
                    self.title = title
                    self.notify(.title)
                    if let url = webView.url, url != self.errorPageURL {
                        Task { await HistoryStore.shared.updateTitle(url: url, title: title) }
                    }
                }
            },
            webView.observe(\.url) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = webView.url else { return }
                    if url.host() != self.url?.host() {
                        self.favicon = FaviconStore.shared.cachedIcon(for: url)
                    }
                    self.url = url
                    self.notify(.url)
                }
            },
            webView.observe(\.themeColor) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.themeColor = webView.themeColor
                    self?.notify(.themeColor)
                }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notify(.loading) }
            },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notify(.progress) }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notify(.navigationState) }
            },
            webView.observe(\.canGoForward) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notify(.navigationState) }
            },
        ]
    }

    private func detach(_ webView: WKWebView) {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
    }

    /// Call when the tab closes, so the web process can end.
    func close() {
        if let webView { detach(webView) }
    }

    private func notify(_ change: Change) {
        store?.tabDidChange(self, change)
    }
}
