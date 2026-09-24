import AppKit

/// The top bar button for downloads. It shows only when there are downloads, and it
/// opens a list with progress, and "Show in Finder" and "Move to Trash" buttons.
@MainActor
final class DownloadsButton: NSButton {
    private let popover = NSPopover()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloads")
        symbolConfiguration = .init(pointSize: 14, weight: .medium)
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = "Downloads"
        target = self
        action = #selector(toggle)
        popover.behavior = .transient
        isHidden = true
        DownloadManager.shared.addObserver(self) { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var fittingSize: NSSize { isHidden ? .zero : NSSize(width: 28, height: 28) }

    private func refresh() {
        isHidden = DownloadManager.shared.items.isEmpty
        superview?.needsLayout = true
        contentTintColor = DownloadManager.shared.hasRunningDownloads ? .controlAccentColor : .secondaryLabelColor
        guard popover.isShown else { return }
        // The button hides when the list is empty, so the popover must not stay open.
        if isHidden { return popover.close() }
        popover.contentViewController = DownloadsList()
    }

    @objc private func toggle() {
        if popover.isShown { return popover.close() }
        popover.contentViewController = DownloadsList()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

/// The popover content: one line per download.
@MainActor
private final class DownloadsList: NSViewController {
    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for item in DownloadManager.shared.items.prefix(10) {
            stack.addArrangedSubview(row(for: item))
        }
        if DownloadManager.shared.items.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "No downloads"))
        }
        view = stack
        // The popover takes this size. Without it, the popover is narrower than the rows
        // and they go past the edges.
        preferredContentSize = stack.fittingSize
    }

    private func row(for item: DownloadManager.Item) -> NSView {
        let name = NSTextField(labelWithString: item.filename.isEmpty ? "Starting…" : item.filename)
        name.lineBreakMode = .byTruncatingMiddle
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let status: NSView
        switch item.state {
        case .running:
            let bar = NSProgressIndicator()
            bar.isIndeterminate = item.download.progress.totalUnitCount <= 0
            bar.doubleValue = item.download.progress.fractionCompleted * 100
            bar.widthAnchor.constraint(equalToConstant: 100).isActive = true
            status = bar
        case .finished:
            let path = item.destination?.path ?? ""
            let buttons = [
                smallButton("magnifyingglass", "Show in Finder", #selector(DownloadActions.reveal(_:)), path),
                smallButton("trash", "Move to Trash", #selector(DownloadActions.delete(_:)), path),
            ]
            status = NSStackView(views: buttons)
        case .failed:
            let label = NSTextField(labelWithString: "Failed")
            label.textColor = .systemRed
            status = label
        }
        return NSStackView(views: [name, status])
    }

    private func smallButton(_ symbol: String, _ tip: String, _ action: Selector, _ path: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                              target: DownloadActions.shared, action: action)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.identifier = NSUserInterfaceItemIdentifier(path)
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
}

@MainActor
private final class DownloadActions: NSObject {
    static let shared = DownloadActions()
    @objc func reveal(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func delete(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, !path.isEmpty,
              let item = DownloadManager.shared.items.first(where: { $0.destination?.path == path }) else { return }
        DownloadManager.shared.delete(item)
    }
}
