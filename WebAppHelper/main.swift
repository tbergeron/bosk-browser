import AppKit
import BoskCore
import QuartzCore
import UserNotifications

// A saved web app (Bosk's Save as App). This small app has no web engine: the page lives in Bosk,
// which shares its cookies, extensions and processes with all tabs. This app owns what makes it
// an app of its own: the window, Dock icon, Cmd+Tab entry, menu bar and notifications. It shows
// Bosk's drawing of the page (a CoreAnimation context from Bosk's process) and sends the user's
// input to Bosk. Bosk writes the keys below into each copy's Info.plist.

@MainActor
final class WebApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let info = Bundle.main.infoDictionary ?? [:]
    var name: String { info["CFBundleDisplayName"] as? String ?? "Web App" }
    private var windows: [PageWindowController] = []
    /// The window that showed each notification, so a click goes back to its page.
    private var notificationOwners: [String: WeakController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard info["BoskWebAppURL"] is String, info["BoskSocketPath"] is String else {
            let alert = NSAlert()
            alert.messageText = "This app opens from Bosk"
            alert.informativeText = "In Bosk, use File > Save as App… to make an app for a website."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        NSApp.mainMenu = makeMenu()
        UNUserNotificationCenter.current().delegate = self
        newWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// File > New Window: another window with its own page of the site, like another tab in Bosk.
    @objc func newWindow(_ sender: Any?) {
        let controller = PageWindowController(app: self, savesFrame: windows.isEmpty)
        windows.append(controller)
        controller.connect()
    }

    func windowDidClose(_ controller: PageWindowController) {
        windows.removeAll { $0 === controller }
    }

    // MARK: Notifications (shown with this app's name and icon)

    func notify(_ identifier: String, _ title: String, _ subtitle: String, _ body: String, from controller: PageWindowController) {
        notificationOwners[identifier] = WeakController(controller: controller)
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        await MainActor.run {
            NSApp.activate()
            guard let owner = notificationOwners[identifier]?.controller ?? windows.first else { return }
            owner.window.makeKeyAndOrderFront(nil)
            owner.send(.notificationClicked(identifier))
        }
    }

    // MARK: Menu bar

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        // These go to the front window's page (PageView.menuCommand).
        func command(_ title: String, _ name: String, _ key: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(PageView.menuCommand(_:)), keyEquivalent: key)
            item.representedObject = name
            return item
        }
        add(name, [
            NSMenuItem(title: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            .separator(),
            NSMenuItem(title: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        add("File", [
            NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n"),
            NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ])
        add("Edit", [
            command("Undo", "undo", "z"), command("Redo", "redo", "Z"), .separator(),
            command("Cut", "cut", "x"), command("Copy", "copy", "c"), command("Paste", "paste", "v"),
            command("Select All", "selectAll", "a"),
        ])
        add("View", [
            command("Reload Page", "reload", "r"), .separator(),
            command("Back", "back", "["), command("Forward", "forward", "]"), .separator(),
            command("Zoom In", "zoomIn", "="), command("Zoom Out", "zoomOut", "-"), command("Actual Size", "actualSize", "0"),
        ])
        add("Window", [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
        ])
        return main
    }
}

struct WeakController {
    weak var controller: PageWindowController?
}

/// One window of the web app, with its own page in Bosk and its own link to Bosk.
@MainActor
final class PageWindowController: NSObject, NSWindowDelegate {
    private unowned let app: WebApp
    private var connection: WebAppConnection?
    let window: NSWindow
    private let pageView: PageView

    init(app: WebApp, savesFrame: Bool) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        pageView = PageView(frame: window.contentLayoutRect)
        super.init()
        window.title = app.name
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = pageView
        pageView.controller = self
        if savesFrame {
            window.center()
            window.setFrameAutosaveName("WebAppWindow")
        } else if let front = NSApp.keyWindow {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(pageView)
    }

    private var contentFrame: WebAppRect {
        let rect = window.convertToScreen(window.contentLayoutRect)
        return WebAppRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    func windowDidResize(_ notification: Notification) { send(.frame(contentFrame)) }
    func windowDidMove(_ notification: Notification) { send(.frame(contentFrame)) }
    func windowDidChangeBackingProperties(_ notification: Notification) { send(.frame(contentFrame)) }
    // Key only while this app is active: the page has keyboard focus then.
    func windowDidBecomeKey(_ notification: Notification) { send(.active(true)) }
    func windowDidResignKey(_ notification: Notification) { send(.active(false)) }

    func windowWillClose(_ notification: Notification) {
        connection?.onClose = nil
        connection?.close()
        app.windowDidClose(self)
    }

    func send(_ message: WebAppMessage) { connection?.send(message) }

    // MARK: Link to Bosk

    func connect() {
        Task { await connectToBosk() }
    }

    /// Starts Bosk when it does not run, then waits for its socket.
    private func connectToBosk() async {
        guard let url = app.info["BoskWebAppURL"] as? String, let socketPath = app.info["BoskSocketPath"] as? String else { return }
        var link = WebAppConnection.connect(path: socketPath)
        if link == nil, let hostID = app.info["BoskHostBundleID"] as? String,
           let hostURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hostID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: hostURL, configuration: configuration)
            for _ in 0..<80 where link == nil {
                try? await Task.sleep(for: .milliseconds(250))
                link = WebAppConnection.connect(path: socketPath)
            }
        }
        guard let link else {
            let alert = NSAlert()
            alert.messageText = "Bosk did not open"
            alert.informativeText = "This app shows its website through Bosk. Open Bosk, then open this app again."
            alert.beginSheetModal(for: window) { [weak self] _ in self?.window.close() }
            return
        }
        connection = link
        link.onMessage = { [weak self] message in self?.handle(message) }
        // Bosk quit: the page is gone.
        link.onClose = { [weak self] in self?.window.close() }
        link.start()
        link.send(.hello(url: url, appID: Bundle.main.bundleIdentifier ?? "", frame: contentFrame))
        link.send(.active(window.isKeyWindow))
    }

    private func handle(_ message: WebAppMessage) {
        switch message {
        case .context(let id): pageView.show(contextID: id)
        case .title(let title): window.title = title
        case .cursor(let name): pageView.setCursor(named: name)
        case .dialog(let dialog): show(dialog)
        case let .notify(identifier, title, subtitle, body): app.notify(identifier, title, subtitle, body, from: self)
        case .removeNotification(let identifier):
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        case .close: window.close()
        case .showBosk:
            if let hostID = app.info["BoskHostBundleID"] as? String {
                NSRunningApplication.runningApplications(withBundleIdentifier: hostID).first?.activate()
            }
        default: break
        }
    }

    // MARK: Dialogs

    private func show(_ dialog: WebAppDialog) {
        if dialog.kind == .openFiles {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = dialog.allowsMultiple
            panel.canChooseDirectories = dialog.allowsDirectories
            panel.canChooseFiles = true
            panel.beginSheetModal(for: window) { [weak self] response in
                self?.send(.dialogReply(WebAppDialogReply(id: dialog.id, ok: response == .OK,
                                                          paths: panel.urls.map(\.path))))
            }
            return
        }
        let alert = NSAlert()
        if let host = dialog.host, !host.isEmpty, dialog.kind != .signIn {
            alert.messageText = "“\(host)” says:"
            alert.informativeText = dialog.message
        } else {
            alert.messageText = dialog.message
        }
        var fields: [NSTextField] = []
        switch dialog.kind {
        case .prompt:
            fields = [NSTextField(string: dialog.defaultText ?? "")]
        case .signIn:
            alert.informativeText = "Your password is sent to this site only. Bosk does not save it."
            let user = NSTextField(string: "")
            user.placeholderString = "User name"
            let password = NSSecureTextField(string: "")
            password.placeholderString = "Password"
            fields = [user, password]
        default: break
        }
        if !fields.isEmpty {
            let stack = NSStackView(views: fields)
            stack.orientation = .vertical
            stack.frame = NSRect(x: 0, y: 0, width: 280, height: CGFloat(fields.count) * 32)
            for field in fields { field.widthAnchor.constraint(equalToConstant: 280).isActive = true }
            alert.accessoryView = stack
            alert.window.initialFirstResponder = fields[0]
        }
        alert.addButton(withTitle: dialog.confirmTitle ?? (dialog.kind == .signIn ? "Sign In" : "OK"))
        if dialog.kind != .alert { alert.addButton(withTitle: dialog.cancelTitle ?? "Cancel") }
        alert.beginSheetModal(for: window) { [weak self] response in
            let ok = response == .alertFirstButtonReturn
            self?.send(.dialogReply(WebAppDialogReply(id: dialog.id, ok: ok, text: fields.first?.stringValue,
                                                      password: fields.count > 1 ? fields[1].stringValue : nil)))
        }
    }
}

/// Shows the page and sends the input. It is the text input client, because the Mac text
/// input system (accents, other alphabets) serves only the active app: this one.
@MainActor
final class PageView: NSView, @preconcurrency NSTextInputClient {
    weak var controller: PageWindowController?
    private var host: CALayer?
    private var cursor = NSCursor.arrow
    private var markedText = ""
    /// Collected while the text input system handles one key press.
    private var inKeyDown = false
    private var insertedText: String?
    private var usedMarkedText = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    /// Edit and View menu commands: they go to this window's page in Bosk.
    @objc func menuCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller?.send(.command(name))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    func show(contextID: UInt32) {
        host?.removeFromSuperlayer()
        guard let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type else { return }
        let host = hostClass.init()
        host.setValue(NSNumber(value: contextID), forKey: "contextId")
        host.anchorPoint = .zero
        host.frame = bounds
        host.isGeometryFlipped = true
        layer?.addSublayer(host)
        self.host = host
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host?.frame = bounds
        CATransaction.commit()
    }

    func setCursor(named name: String) {
        cursor = switch name {
        case "iBeam": .iBeam
        case "pointingHand": .pointingHand
        case "crosshair": .crosshair
        case "openHand": .openHand
        case "closedHand": .closedHand
        case "resizeLeftRight": .resizeLeftRight
        case "resizeUpDown": .resizeUpDown
        case "operationNotAllowed": .operationNotAllowed
        default: .arrow
        }
        window?.invalidateCursorRects(for: self)
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { cursor.set() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    // MARK: Mouse

    private func sendMouse(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.send(.mouse(WebAppMouse(type: event.type.rawValue, x: point.x, y: point.y,
                                     flags: event.modifierFlags.rawValue, clicks: event.clickCount)))
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); sendMouse(event) }
    override func mouseUp(with event: NSEvent) { sendMouse(event) }
    override func mouseDragged(with event: NSEvent) { sendMouse(event) }
    override func mouseMoved(with event: NSEvent) { sendMouse(event) }
    override func rightMouseDown(with event: NSEvent) { sendMouse(event) }
    override func rightMouseUp(with event: NSEvent) { sendMouse(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMouse(event) }
    override func otherMouseDown(with event: NSEvent) { sendMouse(event) }
    override func otherMouseUp(with event: NSEvent) { sendMouse(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMouse(event) }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.send(.scroll(WebAppScroll(x: point.x, y: point.y, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                       precise: event.hasPreciseScrollingDeltas, phase: event.phase.rawValue,
                                       momentum: event.momentumPhase.rawValue, flags: event.modifierFlags.rawValue)))
    }

    // MARK: Keys

    private func sendKey(_ event: NSEvent, characters: String? = nil) {
        controller?.send(.key(WebAppKey(type: event.type.rawValue, characters: characters ?? event.characters ?? "",
                                 charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                 keyCode: event.keyCode, flags: event.modifierFlags.rawValue,
                                 isRepeat: event.type == .keyDown && event.isARepeat)))
    }

    override func keyDown(with event: NSEvent) {
        // Shortcuts the menu bar did not take go to the page as they are (Cmd+K in a chat app).
        guard !event.modifierFlags.contains(.command) else { return sendKey(event) }
        let hadMarkedText = hasMarkedText()
        inKeyDown = true
        insertedText = nil
        usedMarkedText = false
        interpretKeyEvents([event])
        inKeyDown = false
        if usedMarkedText || (hadMarkedText && insertedText != nil) {
            return // Sent as text messages: the page shows the composition.
        }
        // A plain key: send the key itself, so the page gets keydown and input. The text system's
        // result (for example "é" after a dead key) replaces the key's own characters.
        sendKey(event, characters: insertedText)
    }

    override func keyUp(with event: NSEvent) { sendKey(event) }
    override func flagsChanged(with event: NSEvent) { sendKey(event) }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        if inKeyDown && markedText.isEmpty {
            insertedText = (insertedText ?? "") + text
        } else {
            controller?.send(.text(insert: true, text: text, selection: 0, length: 0))
            usedMarkedText = true
        }
        markedText = ""
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        usedMarkedText = true
        controller?.send(.text(insert: false, text: markedText, selection: selectedRange.location, length: selectedRange.length))
    }

    func unmarkText() {
        guard !markedText.isEmpty else { return }
        controller?.send(.text(insert: true, text: markedText, selection: 0, length: 0))
        markedText = ""
    }

    // Keys like Delete, Return and the arrows: Bosk's web view does the same command from the key.
    override func doCommand(by selector: Selector) {}

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    /// Where the text system shows its candidate window: near the mouse, the page's caret is in Bosk.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        NSRect(origin: NSEvent.mouseLocation, size: .zero)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { WebApp() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
