import AppKit
import BoskCore
import WebKit

// AppleScript support (Resources/Bosk.sdef). The words are Chrome's, so apps that drive Chrome
// (Aurel, scripts) drive Bosk too: windows with an active tab, tabs with a number id,
// `execute tab javascript "..."`. Private windows are not shown to scripts.

/// A normal browser window, for scripts. A new one each time a script asks; the id is the window number.
@MainActor
@objc(BoskScriptWindow)
final class ScriptWindow: NSObject {
    let controller: BrowserWindowController

    init(_ controller: BrowserWindowController) {
        self.controller = controller
        super.init()
    }

    /// `make new window`: a new normal window with one empty tab. Bosk does not come to the front,
    /// so a script can work in it while the user works in another app.
    nonisolated override init() {
        controller = MainActor.assumeIsolated {
            let controller = (NSApp.delegate as! AppDelegate).openWindow(showCommandBar: false, activates: false)
            controller.store.newTab(url: nil)
            return controller
        }
        super.init()
    }

    @objc var uniqueID: Int { controller.window?.windowNumber ?? 0 }
    @objc var name: String { controller.window?.title ?? "" }

    /// From 1, front to back. Setting 1 puts the window in front of the other Bosk windows,
    /// without making Bosk the active app.
    @objc var orderedIndex: Int {
        get { (NSApp.scriptWindows.firstIndex { $0.controller === controller } ?? 0) + 1 }
        set { if newValue == 1 { controller.window?.orderFront(nil) } }
    }

    /// {left, top, right, bottom}, from the top left of the main screen, as AppleScript gives the bounds of windows.
    @objc var scriptBounds: [Int] {
        get {
            guard let frame = controller.window?.frame, let top = NSScreen.screens.first?.frame.maxY else { return [] }
            return [Int(frame.minX), Int(top - frame.maxY), Int(frame.maxX), Int(top - frame.minY)]
        }
        set {
            guard newValue.count == 4, newValue[2] > newValue[0], newValue[3] > newValue[1],
                  let top = NSScreen.screens.first?.frame.maxY else {
                return scriptError("Give the bounds as {left, top, right, bottom}.")
            }
            controller.window?.setFrame(NSRect(x: newValue[0], y: Int(top) - newValue[3],
                                               width: newValue[2] - newValue[0], height: newValue[3] - newValue[1]), display: true)
        }
    }

    @objc var scriptTabs: [Tab] { controller.store.allTabs }
    @objc var activeTab: Tab? { controller.store.selectedTab }

    @objc var activeTabIndex: Int {
        get { controller.store.selectedTab.flatMap { tab in scriptTabs.firstIndex { $0 === tab } }.map { $0 + 1 } ?? 0 }
        set {
            guard scriptTabs.indices.contains(newValue - 1) else { return scriptError("There is no tab \(newValue).") }
            controller.store.select(scriptTabs[newValue - 1])
        }
    }

    /// `make new tab at end of tabs of w with properties {URL: "..."}`: the tab opens in the
    /// background and starts to load.
    nonisolated override func newScriptingObject(of objectClass: AnyClass, forValueForKey key: String,
                                                 withContentsValue contentsValue: Any?, properties: [String: Any]) -> Any? {
        nonisolated(unsafe) let properties = properties
        return onMainThread { [self] () -> Any? in
            guard key == "scriptTabs" else { return nil }
            var url: URL?
            if let text = properties["scriptURL"] as? String {
                guard let page = AppleScriptPage.url(from: text) else {
                    scriptError("Bosk opens only http and https pages from scripts.")
                    return nil
                }
                url = page
            }
            let tab = controller.store.newTab(url: url, select: false)
            if url != nil { tab.wake() }
            return tab
        }
    }

    /// NSCreateCommand adds the made tab here. newScriptingObject already put it in the window.
    /// Key-value coding uses the insert only when a remove is there too; scripts cannot delete tabs.
    @objc(insertInScriptTabs:) func insertInScriptTabs(_ tab: Tab) {}
    @objc(insertObject:inScriptTabsAtIndex:) func insertInScriptTabs(_ tab: Tab, at index: Int) {}
    @objc(removeObjectFromScriptTabsAtIndex:) func removeFromScriptTabs(at index: Int) {}

    @objc(handleCloseScriptCommand:) func handleClose(_ command: NSCloseCommand) -> Any? {
        // No "Close this window?" question: the script asked, and a modal alert would stop it.
        controller.window?.close()
        return nil
    }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        onMainThread {
            NSUniqueIDSpecifier(containerClassDescription: NSScriptClassDescription(for: NSApplication.self)!,
                                containerSpecifier: nil, key: "scriptWindows", uniqueID: uniqueID)
        }
    }
}

// On NSApplication, not on its delegate: Cocoa scripting sends the insert of `make new window` to the application.
extension NSApplication {
    /// The normal browser windows, front to back.
    @objc var scriptWindows: [ScriptWindow] {
        let normal = (delegate as? AppDelegate)?.windowControllers.filter { !$0.store.isPrivate } ?? []
        let ordered = orderedWindows.compactMap { window in normal.first { $0.window === window } }
        return (ordered + normal.filter { controller in !ordered.contains { $0 === controller } }).map(ScriptWindow.init)
    }

    /// NSCreateCommand adds the made window here. ScriptWindow.init already opened it.
    /// Key-value coding uses the insert only when a remove is there too; scripts close windows with `close`.
    @objc(insertInScriptWindows:) func insertInScriptWindows(_ window: ScriptWindow) {}
    @objc(insertObject:inScriptWindowsAtIndex:) func insertInScriptWindows(_ window: ScriptWindow, at index: Int) {}
    @objc(removeObjectFromScriptWindowsAtIndex:) func removeFromScriptWindows(at index: Int) {}
}

extension AppDelegate {
    @objc func toggleAppleEventsJavaScript(_ sender: NSMenuItem) {
        Preferences.allowsAppleEventsJavaScript.toggle()
        sender.state = Preferences.allowsAppleEventsJavaScript ? .on : .off
    }
}

extension Tab {
    @objc var uniqueID: Int { scriptID }
    @objc var scriptTitle: String { displayTitle }

    @objc var scriptURL: String {
        get { url?.absoluteString ?? "" }
        set {
            guard let url = AppleScriptPage.url(from: newValue) else {
                return scriptError("Bosk opens only http and https pages from scripts.")
            }
            load(url)
        }
    }

    /// `execute tab javascript "..."`: runs the JavaScript in the page and returns its result.
    /// A sleeping tab wakes first. Off until the user turns on View > Developer > Allow JavaScript from Apple Events,
    /// because a script could read any page the user is signed in to.
    @objc(handleExecuteScriptCommand:) func handleExecute(_ command: NSScriptCommand) -> Any? {
        guard Preferences.allowsAppleEventsJavaScript else {
            scriptError("Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, "
                        + "go to View > Developer > Allow JavaScript from Apple Events.", in: command)
            return nil
        }
        guard let source = command.evaluatedArguments?["javascript"] as? String else {
            scriptError("Give the JavaScript to run.", in: command)
            return nil
        }
        // The completion handler runs on the main thread, where Cocoa scripting runs the command.
        nonisolated(unsafe) let command = command
        command.suspendExecution()
        wake().evaluateJavaScript(source) { result, error in
            // undefined is not an error for a script: it is missing value.
            if let error = error as? WKError, error.code != .javaScriptResultTypeIsUnsupported {
                command.scriptErrorNumber = errOSAGeneralError
                command.scriptErrorString = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            }
            command.resumeExecution(withResult: AppleScriptPage.value(result))
        }
        return nil
    }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        onMainThread {
            guard let controller = store?.windowController, !isPrivate else { return nil }
            return NSUniqueIDSpecifier(containerClassDescription: NSScriptClassDescription(for: ScriptWindow.self)!,
                                       containerSpecifier: ScriptWindow(controller).objectSpecifier,
                                       key: "scriptTabs", uniqueID: scriptID)
        }
    }
}

/// Runs `body` on the main actor. Cocoa scripting calls these NSObject overrides on the main thread,
/// but they are not marked so; their values (specifiers, tabs) are not Sendable.
private func onMainThread<T>(_ body: @MainActor () -> T) -> T {
    nonisolated(unsafe) var result: T?
    MainActor.assumeIsolated { result = body() }
    return result!
}

/// Fails the running AppleScript command with this message.
@MainActor
private func scriptError(_ message: String, in command: NSScriptCommand? = NSScriptCommand.current()) {
    command?.scriptErrorNumber = errOSAGeneralError
    command?.scriptErrorString = message
}
