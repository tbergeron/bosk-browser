import AppKit
import BoskCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowControllers: [BrowserWindowController] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        BookmarkStore.shared.load()
        Preferences.applyAppearance()
        Updater.start()
        SessionStore.shared.snapshotProvider = { [weak self] in
            Session(windows: self?.windowControllers.map(\.windowState) ?? [],
                    pinned: PinnedStore.shared.entries)
        }
        restoreSession()
        ExtensionManager.shared.windowsProvider = { [weak self] in self?.windowControllers ?? [] }
        // Runs when the first window frame is committed. Extensions load after it,
        // so they never slow the launch.
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                #if DEBUG
                ProcessReport.recordLaunchTime()
                #endif
                Task { await ExtensionManager.shared.loadInstalledExtensions() }
            }
        }
        TabSleepManager.shared.storesProvider = { [weak self] in self?.windowControllers.map(\.store) ?? [] }
        TabSleepManager.shared.start()
        #if DEBUG
        if let controller = windowControllers.first {
            PerfHarness.runIfRequested(controller)
            PerfHarness.installExtensionIfRequested(controller)
            PerfHarness.installWebStoreExtensionsIfRequested(controller)
        }
        ProcessReport.start { [weak self] in self?.windowControllers.map(\.store) ?? [] }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionStore.shared.saveNow()
        ExtensionManager.shared.saveRegistry()
    }

    /// Reopens the saved windows. Their tabs sleep until selected.
    private func restoreSession() {
        let session = SessionStore.shared.load()
        PinnedStore.shared.restore(session?.pinned ?? [])
        guard let session, !session.windows.isEmpty else {
            openWindow()
            return
        }
        for state in session.windows {
            let controller = BrowserWindowController(restoring: state)
            windowControllers.append(controller)
            ExtensionManager.shared.controller.didOpenWindow(controller)
            controller.showWindow(nil)
            if controller.store.selectedTab == nil { controller.showCommandBar(target: .newTab) }
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openWindow() }
        return true
    }

    /// Links from other apps open in a new tab in the front window.
    func application(_ application: NSApplication, open urls: [URL]) {
        let controller = (NSApp.mainWindow?.windowController as? BrowserWindowController)
            ?? windowControllers.last ?? openWindow(showCommandBar: false)
        for url in urls { controller.store.newTab(url: url) }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    func openWindow(showCommandBar: Bool = true, frame: NSRect? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController()
        if let frame { controller.window?.setFrame(frame, display: false) }
        windowControllers.append(controller)
        ExtensionManager.shared.controller.didOpenWindow(controller)
        controller.showWindow(nil)
        NSApp.activate()
        if showCommandBar { controller.showCommandBar(target: .newTab) }
        return controller
    }

    /// Moves a normal tab, with its page, to a new window of the same size.
    /// - Parameter topLeft: The new window's top-left corner (where a tab drag ended);
    ///   nil puts the window down and to the right of the tab's window.
    func moveToNewWindow(_ tab: Tab, topLeft: NSPoint? = nil) {
        guard let store = tab.store, let oldFrame = store.window?.frame else { return }
        var frame = oldFrame
        if let topLeft {
            frame.origin = NSPoint(x: topLeft.x, y: topLeft.y - frame.height)
        } else {
            frame = frame.offsetBy(dx: 24, dy: -24)
        }
        let controller = openWindow(showCommandBar: false, frame: frame)
        store.transfer(tab, to: controller.store)
    }

    func windowControllerDidClose(_ controller: BrowserWindowController) {
        // On quit, windows close after the session is saved; keep them in the session.
        guard !isTerminating else { return }
        windowControllers.removeAll { $0 === controller }
        SessionStore.shared.setNeedsSave()
    }

    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quit stops running downloads and leaves partial files, so ask first.
        if DownloadManager.shared.hasRunningDownloads {
            let alert = NSAlert()
            alert.messageText = "Quit and stop downloads?"
            alert.informativeText = "Downloads that are not complete will stop."
            alert.addButton(withTitle: "Quit").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        isTerminating = true
        return .terminateNow
    }

    var allTabs: [Tab] { windowControllers.flatMap(\.store.allTabs) }

    /// Selects a tab in whatever window has it, and brings that window to the front.
    func showTab(id: UUID) {
        for controller in windowControllers {
            guard let tab = controller.store.allTabs.first(where: { $0.id == id }) else { continue }
            controller.store.select(tab)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
    }

    // MARK: Menu actions when no browser window is in front

    @objc func newWindow(_ sender: Any?) { openWindow() }
    /// Cmd+W in a window that has no tabs (Settings, About) closes that window.
    @objc func closeTab(_ sender: Any?) {
        guard let window = NSApp.keyWindow, window.styleMask.contains(.closable) else { return }
        window.performClose(sender)
    }
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    /// History > Clear History…. Same question as Settings > Privacy.
    @objc func clearHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "Command bar suggestions forget every page you visited."
        alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await HistoryStore.shared.clear() }
    }

    /// Settings > About: the version, updates, and the shortcuts.
    @objc func showAbout(_ sender: Any?) { SettingsWindowController.shared.show(pane: .about) }
    @objc func checkForUpdates(_ sender: Any?) { Updater.checkForUpdates() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates(_:)) || Updater.isConfigured
    }
    @objc func newTab(_ sender: Any?) { openWindow() }
}
