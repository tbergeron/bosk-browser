import AppKit

/// The menu bar, built in code (no storyboard or XIB). Browser actions go to the
/// first responder, so the front BrowserWindowController (or AppDelegate) handles them.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Bosk",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Bosk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Bosk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "Bosk", to: main)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"))
        fileMenu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        fileMenu.addItem(item("Open Location…", #selector(BrowserWindowController.openLocation(_:)), "l"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Close Tab", #selector(BrowserWindowController.closeTab(_:)), "w"))
        fileMenu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "W"))
        fileMenu.addItem(item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "T"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Print…", #selector(BrowserWindowController.printPage(_:)), "p"))
        add(fileMenu, title: "File", to: main)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(item("Find…", #selector(BrowserWindowController.showFindBar(_:)), "f"))
        editMenu.addItem(item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g"))
        editMenu.addItem(item("Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "G"))
        add(editMenu, title: "Edit", to: main)

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item("Reload Page", #selector(BrowserWindowController.browserReload(_:)), "r"))
        viewMenu.addItem(item("Stop", #selector(BrowserWindowController.browserStop(_:)), "."))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "="))
        viewMenu.addItem(item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+", alternate: true))
        viewMenu.addItem(item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"))
        viewMenu.addItem(item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Fold Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s"))
        viewMenu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        add(viewMenu, title: "View", to: main)

        let historyMenu = NSMenu(title: "History")
        historyMenu.addItem(item("Back", #selector(BrowserWindowController.browserBack(_:)), "["))
        historyMenu.addItem(item("Forward", #selector(BrowserWindowController.browserForward(_:)), "]"))
        add(historyMenu, title: "History", to: main)

        let tabsMenu = NSMenu(title: "Tabs")
        tabsMenu.addItem(item("Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "\t", [.control]))
        tabsMenu.addItem(item("Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "\t", [.control, .shift]))
        tabsMenu.addItem(item("Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "}", [.command, .shift], alternate: true))
        tabsMenu.addItem(item("Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "{", [.command, .shift], alternate: true))
        tabsMenu.addItem(.separator())
        tabsMenu.addItem(item("Pin or Unpin Tab", #selector(BrowserWindowController.togglePinTab(_:)), "d"))
        tabsMenu.addItem(.separator())
        for number in 1...9 {
            let entry = item(number == 9 ? "Last Tab" : "Tab \(number)",
                             #selector(BrowserWindowController.selectTabByNumber(_:)), "\(number)")
            entry.tag = number
            tabsMenu.addItem(entry)
        }
        add(tabsMenu, title: "Tabs", to: main)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(windowMenu, title: "Window", to: main)
        NSApp.windowsMenu = windowMenu

        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = .command,
                             alternate: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // A hidden second shortcut for the same command (Cmd+Shift+] as well as Ctrl+Tab).
        if alternate { item.isHidden = true; item.allowsKeyEquivalentWhenHidden = true }
        return item
    }

    private static func add(_ submenu: NSMenu, title: String, to main: NSMenu) {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
    }
}
