import AppKit
import BoskCore
import WebKit

/// Runs the pages of saved web apps (Save as App). Each web app is a small helper app with its own
/// window, Dock icon and menu bar; its page is a tab here, so it shares cookies, extensions and
/// processes with Bosk's other tabs. The helper shows this tab's drawing (a CoreAnimation
/// context) and sends the user's input. See WebAppHelper/main.swift.
@MainActor
final class WebAppHost {
    static let shared = WebAppHost()
    /// The helpers find the socket through their Info.plist (Save as App writes it).
    static let socketPath = Defaults.dataDirectory.appending(path: "webapps.sock").path

    private var listener: WebAppListener?
    private(set) var sessions: [WebAppSession] = []

    var tabs: [Tab] { sessions.compactMap(\.tab) }

    func start() {
        try? FileManager.default.createDirectory(at: Defaults.dataDirectory, withIntermediateDirectories: true)
        listener = WebAppListener(path: Self.socketPath)
        listener?.onConnection = { [weak self] connection in
            guard let self else { return }
            let session = WebAppSession(connection: connection)
            session.onEnd = { [weak self, weak session] in self?.sessions.removeAll { $0 === session } }
            sessions.append(session)
            connection.start()
        }
    }

    func session(for tab: Tab) -> WebAppSession? { sessions.first { $0.tab === tab } }
}

/// One running web app: its tab, the window that holds the page, and the link to its helper.
@MainActor
final class WebAppSession: TabStoreDelegate {
    private let connection: WebAppConnection
    private(set) var tab: Tab?
    let store = TabStore(isWebApp: true)
    /// The web app's name, for the Tab Manager.
    private(set) var appName: String?
    private var window: WebAppWindow?
    /// The page's drawing, which the helper shows with a CALayerHost (see `show`).
    private var drawingContext: NSObject?
    private var drawingTimer: Timer?
    private var menuObserver: NSObjectProtocol?
    var onEnd: (() -> Void)?
    /// The helper is the active app, so the page has keyboard focus.
    private(set) var isActive = false
    private var lastCursor = ""
    private var nextDialogID = 1
    private var pendingDialogs: [Int: CheckedContinuation<WebAppDialogReply?, Never>] = [:]

    init(connection: WebAppConnection) {
        self.connection = connection
        store.delegate = self
        connection.onMessage = { [weak self] message in self?.handle(message) }
        connection.onClose = { [weak self] in self?.end() }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepDrawingContext() }
        }
    }

    private func handle(_ message: WebAppMessage) {
        switch message {
        case let .hello(url, appID, frame):
            appName = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first?.localizedName
            open(url: url, frame: frame)
        case .frame(let frame):
            window?.place(at: frame)
            keepDrawingContext()
        case .active(let active): setActive(active)
        case .mouse(let mouse): deliver(mouse)
        case .scroll(let scroll): deliver(scroll)
        case .key(let key): deliver(key)
        case let .text(insert, text, selection, length): deliver(text: text, insert: insert, selection: selection, length: length)
        case .command(let name): perform(name)
        case .dialogReply(let reply): pendingDialogs.removeValue(forKey: reply.id)?.resume(returning: reply)
        case .notificationClicked(let identifier):
            WebNotifications.clicked(identifier: identifier, origin: WebNotifications.origin(of: tab?.url))
        default: break
        }
    }

    private func open(url string: String, frame: WebAppRect) {
        guard tab == nil, let url = URL(string: string), ["http", "https"].contains(url.scheme) else { return end() }
        let window = WebAppWindow(session: self)
        window.place(at: frame)
        self.window = window
        store.window = window
        let tab = Tab(url: url)
        tab.favicon = FaviconStore.shared.cachedIcon(for: url)
        self.tab = tab
        store.insert(tab, after: nil, select: true)
        // The wake tells the store (.sleepState), and `tabStore(_:didUpdate:change:)` shows the page.
        tab.wake()
        connection.send(.title(tab.displayTitle))
    }

    /// Puts the web view in the window and gives the helper the page's drawing.
    private func show(_ webView: WKWebView) {
        guard let window else { return }
        (webView as? BoskWebView)?.isInWebApp = true
        WebAppWindow.disableOcclusionDetection(webView)
        window.contentView = webView
        webView.wantsLayer = true
        window.orderFrontRegardless()
        guard let layer = webView.layer, let context = WebAppWindow.makeRemoteContext(),
              let id = context.value(forKey: "contextId") as? UInt32 else {
            return NSLog("Bosk: a web app page has no CoreAnimation context")
        }
        context.setValue(layer, forKey: "layer")
        drawingContext = context
        connection.send(.context(id))
        // AppKit puts the layer back in the window's layer tree when it draws the window (the first
        // time 0.2 s after this, and when the page opens a menu), and then the helper shows nothing.
        // So check after each click, when a menu opens, and on a timer that also runs in menus.
        // ponytail: polling; a hook in AppKit's layer updates if a short blank still shows.
        drawingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepDrawingContext() }
        }
        RunLoop.main.add(timer, forMode: .common)
        drawingTimer = timer
    }

    /// The web view's layer is the root of `drawingContext`. Put it back if AppKit took it again.
    private func keepDrawingContext() {
        guard let context = drawingContext, let layer = tab?.webView?.layer,
              context.value(forKey: "layer") as? CALayer !== layer || layer.superlayer != nil else { return }
        context.setValue(layer, forKey: "layer")
    }

    private func setActive(_ active: Bool) {
        isActive = active
        guard let window else { return }
        NotificationCenter.default.post(name: active ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification,
                                        object: window)
        NotificationCenter.default.post(name: active ? NSWindow.didBecomeMainNotification : NSWindow.didResignMainNotification,
                                        object: window)
        if active, let webView = tab?.webView { window.makeFirstResponder(webView) }
    }

    private func end() {
        guard onEnd != nil else { return }
        for continuation in pendingDialogs.values { continuation.resume(returning: nil) }
        pendingDialogs = [:]
        if let tab { store.close(tab) }
        tab = nil
        drawingTimer?.invalidate()
        drawingTimer = nil
        drawingContext = nil
        menuObserver.map(NotificationCenter.default.removeObserver)
        menuObserver = nil
        window?.orderOut(nil)
        window = nil
        connection.close()
        let onEnd = onEnd
        self.onEnd = nil
        onEnd?()
    }

    // MARK: Input

    private func deliver(_ mouse: WebAppMouse) {
        guard let window, let webView = tab?.webView, let type = NSEvent.EventType(rawValue: mouse.type),
              let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: mouse.x, y: mouse.y),
                                             modifierFlags: NSEvent.ModifierFlags(rawValue: mouse.flags),
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: mouse.clicks, pressure: 1) else { return }
        switch type {
        case .mouseMoved: webView.mouseMoved(with: event)
        // Through the app, so the click is `NSApp.currentEvent`: WebKit opens a <select> list and the
        // page menu from the current event. BoskWebView takes the first click in this inactive app.
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            NSApp.sendEvent(event)
            keepDrawingContext()
        default: return
        }
        DispatchQueue.main.async { [weak self] in self?.sendCursor() }
    }

    private func deliver(_ scroll: WebAppScroll) {
        guard let webView = tab?.webView,
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: scroll.precise ? .pixel : .line, wheelCount: 2,
                                    wheel1: Int32(scroll.dy.rounded()), wheel2: Int32(scroll.dx.rounded()), wheel3: 0)
        else { return }
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: scroll.dy)
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: scroll.dx)
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: scroll.precise ? 1 : 0)
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Self.scrollPhase(scroll.phase))
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Self.momentumPhase(scroll.momentum))
        cgEvent.flags = CGEventFlags(rawValue: UInt64(scroll.flags))
        // An event made from a CGEvent has no window, so its "position in the window" is its
        // position on the screen. Put it where that equals the position in the page.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: scroll.x, y: screenHeight - scroll.y)
        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        webView.scrollWheel(with: event)
    }

    /// NSEvent.Phase raw values to the CGScrollPhase values of a CGEvent.
    private static func scrollPhase(_ phase: UInt) -> Int64 {
        let phase = NSEvent.Phase(rawValue: phase)
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) { return 4 }
        if phase.contains(.cancelled) { return 8 }
        if phase.contains(.mayBegin) { return 128 }
        return 0
    }

    /// NSEvent.Phase raw values to the CGMomentumScrollPhase values of a CGEvent.
    private static func momentumPhase(_ phase: UInt) -> Int64 {
        let phase = NSEvent.Phase(rawValue: phase)
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) || phase.contains(.cancelled) { return 3 }
        return 0
    }

    private func deliver(_ key: WebAppKey) {
        guard let window, let webView = tab?.webView, let type = NSEvent.EventType(rawValue: key.type) else { return }
        let flags = NSEvent.ModifierFlags(rawValue: key.flags)
        let time = ProcessInfo.processInfo.systemUptime
        let event: NSEvent? = if type == .flagsChanged {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: time,
                             windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: key.keyCode)
        } else {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: time,
                             windowNumber: window.windowNumber, context: nil, characters: key.characters,
                             charactersIgnoringModifiers: key.charactersIgnoringModifiers, isARepeat: key.isRepeat,
                             keyCode: key.keyCode)
        }
        guard let event else { return }
        switch type {
        case .keyDown: webView.keyDown(with: event)
        case .keyUp: webView.keyUp(with: event)
        case .flagsChanged: webView.flagsChanged(with: event)
        default: break
        }
    }

    /// Composed text from the helper's text input system: accents, other alphabets.
    private func deliver(text: String, insert: Bool, selection: Int, length: Int) {
        guard let client = tab?.webView as? NSTextInputClient else { return }
        let replace = NSRange(location: NSNotFound, length: 0)
        if insert {
            client.insertText(text, replacementRange: replace)
        } else {
            client.setMarkedText(text, selectedRange: NSRange(location: selection, length: length), replacementRange: replace)
        }
    }

    private func perform(_ command: String) {
        guard let tab, let webView = tab.webView else { return }
        switch command {
        case "copy": NSApp.sendAction(#selector(NSText.copy(_:)), to: webView, from: nil)
        case "cut": NSApp.sendAction(#selector(NSText.cut(_:)), to: webView, from: nil)
        case "paste": NSApp.sendAction(#selector(NSText.paste(_:)), to: webView, from: nil)
        case "selectAll": NSApp.sendAction(#selector(NSText.selectAll(_:)), to: webView, from: nil)
        case "undo": webView.undoManager?.undo()
        case "redo": webView.undoManager?.redo()
        case "reload": webView.reload()
        case "back": webView.goBack()
        case "forward": webView.goForward()
        case "zoomIn": tab.changeZoom(larger: true)
        case "zoomOut": tab.changeZoom(larger: false)
        case "actualSize": PageZoom.set(nil, for: tab.url, isPrivate: false)
        default: break
        }
    }

    /// WebKit sets the cursor only when the mouse is over its own window, and the helper's window
    /// is on top. So the helper shows the cursor: the I-beam over text, the hand over links.
    private func sendCursor() {
        let current = NSCursor.current
        var name = switch current {
        case NSCursor.iBeam: "iBeam"
        case NSCursor.pointingHand: "pointingHand"
        case NSCursor.crosshair: "crosshair"
        case NSCursor.openHand: "openHand"
        case NSCursor.closedHand: "closedHand"
        case NSCursor.resizeLeftRight: "resizeLeftRight"
        case NSCursor.resizeUpDown: "resizeUpDown"
        case NSCursor.operationNotAllowed: "operationNotAllowed"
        default: "arrow"
        }
        if name == "arrow", tab?.hoveredLink != nil { name = "pointingHand" }
        guard name != lastCursor else { return }
        lastCursor = name
        connection.send(.cursor(name))
    }

    // MARK: Dialogs and notifications, shown by the helper

    /// Nil when the helper quit before the user answered.
    func ask(_ dialog: WebAppDialog) async -> WebAppDialogReply? {
        var dialog = dialog
        dialog.id = nextDialogID
        nextDialogID += 1
        connection.send(.dialog(dialog))
        return await withCheckedContinuation { pendingDialogs[dialog.id] = $0 }
    }

    func notify(identifier: String, title: String, subtitle: String, body: String) {
        connection.send(.notify(identifier: identifier, title: title, subtitle: subtitle, body: body))
    }

    func removeNotification(_ identifier: String) {
        connection.send(.removeNotification(identifier))
    }

    /// The page opened a tab in a Bosk window. Bosk cannot make itself active while the helper is.
    func showBosk() { connection.send(.showBosk) }

    // MARK: TabStoreDelegate

    func tabStoreDidChangeTabs(_ store: TabStore) {
        // The page closed itself (window.close()).
        if tab != nil, store.tabs.isEmpty {
            connection.send(.close)
            end()
        }
    }

    func tabStore(_ store: TabStore, didUpdate tab: Tab, change: Tab.Change) {
        switch change {
        case .title: connection.send(.title(tab.displayTitle))
        // A crashed page loads again in a new web view.
        case .sleepState: if let webView = tab.webView, webView.window == nil { show(webView) }
        case .hoveredLink: sendCursor()
        default: break
        }
    }

    func tabStore(_ store: TabStore, didSelect tab: Tab?, previous: Tab?) {}
}

/// The window that holds a web app's page. It is invisible and lets clicks through: the helper's
/// window, at the same place on the screen, shows the page. It stays at that place so that the
/// page's menus and pop-up lists open in the right place.
@MainActor
final class WebAppWindow: NSWindow {
    private(set) weak var session: WebAppSession?

    init(session: WebAppSession) {
        self.session = session
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        alphaValue = 0
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // Not in Mission Control, Exposé or the Window menu.
        collectionBehavior = [.transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // This app is never the active app while the helper is in front, so the window is never key
    // for real. WebKit shows the caret and takes keys only in a key window.
    override var isKeyWindow: Bool { session?.isActive ?? false }
    override var isMainWindow: Bool { session?.isActive ?? false }

    func place(at frame: WebAppRect) {
        setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: true)
    }

    /// Private: a CoreAnimation context that another process can show with a CALayerHost, as WebKit
    /// and Chrome make for their processes. Not the window's own context: this window is invisible,
    /// so macOS does not draw its context, and the helper's copy of it froze on screen (only
    /// screenshots, which draw it fresh, showed the changes).
    static func makeRemoteContext() -> NSObject? {
        let selector = NSSelectorFromString("remoteContextWithOptions:")
        guard let contextClass = NSClassFromString("CAContext"),
              let method = class_getClassMethod(contextClass, selector),
              let types = method_getTypeEncoding(method), String(cString: types) == "@24@0:8@16" else { return nil }
        typealias Make = @convention(c) (AnyClass, Selector, NSDictionary) -> Unmanaged<NSObject>?
        return unsafeBitCast(method_getImplementation(method), to: Make.self)(contextClass, selector, [:])?.takeUnretainedValue()
    }

    /// Private: WebKit stops drawing a page whose window is covered, and this window is always covered.
    static func disableOcclusionDetection(_ webView: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector),
              let types = method_getTypeEncoding(method), String(cString: types) == "v20@0:8B16" else { return }
        typealias SetEnabled = @convention(c) (WKWebView, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: SetEnabled.self)(webView, selector, false)
    }
}
