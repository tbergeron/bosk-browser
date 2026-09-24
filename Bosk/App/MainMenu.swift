import AppKit
import BoskCore

/// The menu bar, built in code (no storyboard or XIB). Browser actions go to the
/// first responder, so the front BrowserWindowController (or AppDelegate) handles them.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Bosk", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
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
        // No shortcut: Cmd+P is Search Commands.
        fileMenu.addItem(withTitle: "Print…", action: #selector(BrowserWindowController.printPage(_:)), keyEquivalent: "")
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
        viewMenu.addItem(item("Search Commands…", #selector(BrowserWindowController.searchCommands(_:)), "p"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Reload Page", #selector(BrowserWindowController.browserReload(_:)), "r"))
        viewMenu.addItem(item("Stop", #selector(BrowserWindowController.browserStop(_:)), "."))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Show Reader", #selector(BrowserWindowController.toggleReader(_:)), "R"))
        viewMenu.addItem(withTitle: "Allow Ads on This Site", action: #selector(BrowserWindowController.toggleAdsOnSite(_:)),
                         keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "="))
        viewMenu.addItem(item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+", alternate: true))
        viewMenu.addItem(item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"))
        viewMenu.addItem(item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Fold Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s"))
        viewMenu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        add(viewMenu, title: "View", to: main)

        let tabsMenu = NSMenu(title: "Tabs")
        tabsMenu.addItem(item("Search Tabs…", #selector(BrowserWindowController.searchTabs(_:)), "A"))
        tabsMenu.addItem(.separator())
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

        let historyMenu = NSMenu(title: "History")
        historyMenu.addItem(item("Back", #selector(BrowserWindowController.browserBack(_:)), "["))
        historyMenu.addItem(item("Forward", #selector(BrowserWindowController.browserForward(_:)), "]"))
        historyMenu.addItem(.separator())
        historyMenu.addItem(item("Show All History", #selector(BrowserWindowController.showHistory(_:)), "y"))
        historyMenu.addItem(.separator())
        historyMenu.addItem(withTitle: "Clear History…", action: #selector(AppDelegate.clearHistory(_:)), keyEquivalent: "")
        add(historyMenu, title: "History", to: main)

        let bookmarksMenu = NSMenu(title: "Bookmarks")
        bookmarksMenu.addItem(item("Bookmark This Page", #selector(BrowserWindowController.bookmarkPage(_:)), "B"))
        bookmarksMenu.addItem(item("Show Bookmarks", #selector(BrowserWindowController.showBookmarks(_:)), "b",
                                   [.command, .option]))
        bookmarksMenu.addItem(.separator())
        bookmarksMenu.delegate = bookmarksMenuDelegate
        add(bookmarksMenu, title: "Bookmarks", to: main)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(windowMenu, title: "Window", to: main)
        NSApp.windowsMenu = windowMenu

        return main
    }

    /// The menu bar items for Search Commands, with the name of their menu.
    /// Titles and on/off states are current, because each menu is updated first.
    static func commands() -> [(menu: String, item: NSMenuItem)] {
        var commands: [(menu: String, item: NSMenuItem)] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            // The Bookmarks menu makes its bookmark items only when it opens.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.hasSubmenu {
                guard let action = item.action, !hiddenCommands.contains(action) else { continue }
                commands.append((top.title, item))
            }
        }
        return commands
    }

    /// Search Commands itself, and the text-editing items: in the bar, they would act on
    /// the bar's own text field.
    private static let hiddenCommands: Set<Selector> = [
        #selector(BrowserWindowController.searchCommands(_:)),
        Selector(("undo:")), Selector(("redo:")),
        #selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)),
        #selector(NSText.selectAll(_:)),
    ]

    /// "⇧⌘T", as the menu bar shows the shortcut; empty if the item has none.
    static func shortcut(of item: NSMenuItem) -> String {
        let modifiers = item.keyEquivalentModifierMask
        return SuggestionRanker.shortcutText(key: item.keyEquivalent,
                                             control: modifiers.contains(.control), option: modifiers.contains(.option),
                                             shift: modifiers.contains(.shift), command: modifiers.contains(.command))
    }

    /// NSMenu does not keep its delegate.
    private static let bookmarksMenuDelegate = BookmarksMenuDelegate()

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

/// Lists the bookmarks under the fixed items of the Bookmarks menu, each time the menu opens.
@MainActor
private final class BookmarksMenuDelegate: NSObject, NSMenuDelegate {
    /// Bookmark This Page, Show Bookmarks, and the separator.
    private let fixedItemCount = 3

    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.items.count > fixedItemCount { menu.removeItem(at: fixedItemCount) }
        let bookmarks = BookmarkStore.shared.entries
        guard !bookmarks.isEmpty else {
            menu.addItem(withTitle: "No Bookmarks", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        for bookmark in bookmarks {
            let item = ClosureMenuItem(bookmark.title.isEmpty ? bookmark.url.absoluteString : bookmark.title) {
                // A new tab in the front window.
                (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [bookmark.url])
            }
            let icon = (FaviconStore.shared.cachedIcon(for: bookmark.url)
                ?? NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil))?.copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
    }
}
