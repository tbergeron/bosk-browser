import AppKit

/// The title of a tab in the folded sidebar, shown at once to the right of the hovered icon.
/// The system tooltip waits about a second, which is slow when the icons are all there is.
@MainActor
enum SidebarTooltip {
    private static var panel: NSPanel?
    private static let label = NSTextField(labelWithString: "")
    /// The view the tooltip is for; `hide(for:)` from another view does nothing.
    private static weak var owner: NSView?

    /// Only in the key window. The panel is a child window, and a child brings its parent to the front:
    /// a hover on a window behind Settings or the command bar put that window over them.
    static func show(_ text: String, for view: NSView) {
        guard let window = view.window, window.isKeyWindow, !text.isEmpty else { return hide() }
        let panel = panel ?? makePanel()
        label.stringValue = text
        let padding = NSSize(width: 8, height: 4)
        let textSize = label.fittingSize
        let size = NSSize(width: min(textSize.width, 320) + padding.width * 2, height: textSize.height + padding.height * 2)
        label.frame = NSRect(x: padding.width, y: padding.height, width: size.width - padding.width * 2, height: textSize.height)
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        panel.setFrame(NSRect(x: anchor.maxX + 6, y: anchor.midY - size.height / 2, width: size.width, height: size.height),
                       display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        owner = view
    }

    /// - Parameter view: Hide only when the tooltip is for this view; nil hides it for any view.
    static func hide(for view: NSView? = nil) {
        guard view == nil || owner === view else { return }
        owner = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        label.font = .toolTipsFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        background.addSubview(label)
        panel.contentView = background
        self.panel = panel
        return panel
    }
}
