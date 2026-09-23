import AppKit
import BoskCore
import WebKit

/// Extension action buttons in the top bar: icon, badge text, click to run the action
/// (or show its popup).
@MainActor
final class ExtensionActionsView: NSView {
    var currentTab: () -> Tab? = { nil }
    private var buttons: [String: NSButton] = [:]
    private var order: [String] = []

    override var fittingSize: NSSize { NSSize(width: CGFloat(order.count) * 30, height: 28) }

    func reload() {
        let contexts = ExtensionManager.shared.loadedContexts
        let ids = contexts.map(\.uniqueIdentifier)
        for (id, button) in buttons where !ids.contains(id) {
            button.removeFromSuperview()
            buttons[id] = nil
        }
        order = ids
        for context in contexts {
            let id = context.uniqueIdentifier
            let button = buttons[id] ?? makeButton(id)
            buttons[id] = button
            let action = context.action(for: currentTab())
            button.image = action?.icon(for: NSSize(width: 16, height: 16))
                ?? context.webExtension.icon(for: NSSize(width: 16, height: 16))
                ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            button.toolTip = action?.label ?? context.webExtension.displayName
            button.setAccessibilityLabel(button.toolTip)
            button.isEnabled = action?.isEnabled ?? true
            (button as? BadgeButton)?.badge = action?.badgeText ?? ""
        }
        needsLayout = true
        superview?.needsLayout = true
    }

    private func makeButton(_ id: String) -> NSButton {
        let button = BadgeButton()
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(clicked(_:))
        button.identifier = NSUserInterfaceItemIdentifier(id)
        addSubview(button)
        return button
    }

    func button(for context: WKWebExtensionContext) -> NSView? {
        buttons[context.uniqueIdentifier]
    }

    override func layout() {
        super.layout()
        for (index, id) in order.enumerated() {
            buttons[id]?.frame = NSRect(x: CGFloat(index) * 30, y: 0, width: 28, height: 28)
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let context = ExtensionManager.shared.contexts[id] else { return }
        context.performAction(for: currentTab())
    }
}

/// A button with a small badge (an extension's badge text, such as a count).
@MainActor
private final class BadgeButton: NSButton {
    var badge = "" {
        didSet {
            badgeLayer.string = badge
            badgeLayer.isHidden = badge.isEmpty
        }
    }
    private let badgeLayer = CATextLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        badgeLayer.fontSize = 8
        badgeLayer.font = NSFont.boldSystemFont(ofSize: 8)
        badgeLayer.alignmentMode = .center
        badgeLayer.foregroundColor = NSColor.white.cgColor
        badgeLayer.backgroundColor = NSColor.systemRed.cgColor
        badgeLayer.cornerRadius = 5
        badgeLayer.contentsScale = 2
        badgeLayer.isHidden = true
        layer?.addSublayer(badgeLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let width = max(12, CGFloat(badge.count) * 5 + 6)
        badgeLayer.frame = NSRect(x: bounds.maxX - width, y: 0, width: width, height: 10)
    }
}

/// "Add to Bosk" on a Chrome Web Store extension page.
@MainActor
final class AddToBoskButton: NSButton {
    private var extensionID: String?

    init() {
        super.init(frame: .zero)
        title = "Add to Bosk"
        bezelStyle = .push
        controlSize = .small
        target = self
        action = #selector(add)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var fittingSize: NSSize { isHidden ? .zero : super.fittingSize }

    func update(for url: URL?) {
        extensionID = url.flatMap(ChromeExtensionPackage.webStoreExtensionID)
        isHidden = extensionID == nil
        superview?.needsLayout = true
    }

    @objc private func add() {
        guard let extensionID else { return }
        let window = window
        isEnabled = false
        title = "Adding…"
        Task {
            do {
                try await ExtensionManager.shared.installFromWebStore(extensionID: extensionID, in: window)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The extension did not install"
                alert.informativeText = error.localizedDescription
                if let window { await alert.beginSheetModal(for: window) }
            }
            isEnabled = true
            title = "Add to Bosk"
        }
    }
}
