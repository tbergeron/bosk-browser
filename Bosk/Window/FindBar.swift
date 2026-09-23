import AppKit
import WebKit

/// Find in page (Cmd+F). Return finds the next match, Shift+Return the previous one,
/// Escape closes the bar.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    var onClose: (() -> Void)?
    weak var webView: WKWebView?

    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        field.placeholderString = "Find in page"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(findNext)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        doneButton.bezelStyle = .accessoryBarAction
        doneButton.target = self
        doneButton.action = #selector(close)
        [field, status, doneButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        doneButton.frame = NSRect(x: bounds.maxX - 70, y: midY - 11, width: 60, height: 22)
        field.frame = NSRect(x: bounds.maxX - 330, y: midY - 11, width: 240, height: 22)
        status.frame = NSRect(x: field.frame.minX - 130, y: midY - 8, width: 120, height: 16)
        status.alignment = .right
    }

    func controlTextDidChange(_ obj: Notification) { find(backwards: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        case #selector(NSResponder.insertNewline(_:)):
            find(backwards: NSEvent.modifierFlags.contains(.shift))
        default:
            return false
        }
        return true
    }

    @objc func findNext() { find(backwards: false) }
    @objc func findPrevious() { find(backwards: true) }
    @objc private func close() { onClose?() }

    private func find(backwards: Bool) {
        let text = field.stringValue
        guard let webView, !text.isEmpty else {
            status.stringValue = ""
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in
            self?.status.stringValue = result.matchFound ? "" : "Not found"
        }
    }
}
