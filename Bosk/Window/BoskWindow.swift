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
}
