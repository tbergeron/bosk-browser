import AppKit

/// The browser window. Extension keyboard commands (manifest "commands") are checked
/// before the menu shortcuts.
final class BoskWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        for context in ExtensionManager.shared.loadedContexts where context.performCommand(for: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// AppKit puts the window buttons near the top edge. This makes the title bar as tall
    /// as a standard toolbar, so the buttons are centered on the same line as the top bar buttons,
    /// with the same space to their left as above them.
    /// AppKit sets the title bar frames again in each window layout, so the content view
    /// calls this in its layout.
    func centerWindowButtons() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return }
        let height = Defaults.titleBarHeight
        let containerFrame = NSRect(x: 0, y: frame.height - height, width: frame.width, height: height)
        if container.frame != containerFrame { container.frame = containerFrame }
        if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
        let y = ((height - close.frame.height) / 2).rounded()
        // Move all three buttons by the same amount, so the space between them stays.
        let dx = y - close.frame.minX
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            let origin = NSPoint(x: button.frame.minX + dx, y: y)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}
