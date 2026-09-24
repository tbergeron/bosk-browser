import AppKit
import BoskCore

/// The browser window. Extension keyboard commands (manifest "commands") are checked
/// before the web page and the menu shortcuts, but an extension cannot take a key that
/// a menu bar item uses.
final class BoskWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !Self.menuUses(event, in: NSApp.mainMenu) {
            for context in ExtensionManager.shared.loadedContexts where context.performCommand(for: event) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// True if an item in `menu` (or its submenus) has the shortcut of `event`. This only
    /// checks; the menu gets the event after the web page, as before.
    private static func menuUses(_ event: NSEvent, in menu: NSMenu?) -> Bool {
        // Caps Lock gives an uppercase letter with no Shift flag.
        let characters = event.charactersIgnoringModifiers ?? ""
        let key = shortcutText(key: event.modifierFlags.contains(.shift) ? characters : characters.lowercased(),
                               modifiers: event.modifierFlags)
        guard !key.isEmpty else { return false }
        func search(_ menu: NSMenu) -> Bool {
            menu.items.contains { item in
                shortcutText(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask) == key
                    || item.submenu.map(search) == true
            }
        }
        return menu.map(search) ?? false
    }

    /// The same text for an event and a menu item with the same keys. Shift is kept only for
    /// letters: "}" already includes Shift, and a "+" item (no Shift flag) must match Shift+=.
    private static func shortcutText(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        let isLetter = key.lowercased() != key.uppercased()
        return SuggestionRanker.shortcutText(key: key, control: modifiers.contains(.control),
                                             option: modifiers.contains(.option),
                                             shift: isLetter && modifiers.contains(.shift),
                                             command: modifiers.contains(.command))
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        // AppKit sometimes puts the window buttons back at its own position (for example at
        // launch) with no layout of the content view. Move them again when their frames change.
        guard let close = standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return }
        for view in [close, titlebar, container] {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { [weak self] _ in
                // AppKit ignores a button move made while it moves the button (for example in
                // `_updateButtonPositions`, after each title change), so move them after it.
                DispatchQueue.main.async { self?.centerWindowButtons() }
            }
        }
    }

    /// AppKit puts the window buttons near the top edge. This makes the title bar as tall as the
    /// folded top bar, so the buttons are centered on its line. They stay at this position when
    /// the sidebar opens and folds. The space to their left is the space above them in the
    /// `titleBarHeight` title bar.
    /// AppKit sets the title bar frames again in each window layout, so the content view
    /// calls this in its layout.
    func centerWindowButtons() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return }
        let height = Defaults.titleBarHeight - Defaults.contentInset
        let containerFrame = NSRect(x: 0, y: frame.height - height, width: frame.width, height: height)
        if container.frame != containerFrame { container.frame = containerFrame }
        if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
        let y = ((height - close.frame.height) / 2).rounded()
        let x = ((Defaults.titleBarHeight - close.frame.height) / 2).rounded()
        // Move all three buttons by the same amount, so the space between them stays.
        let dx = x - close.frame.minX
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            let origin = NSPoint(x: button.frame.minX + dx, y: y)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}
