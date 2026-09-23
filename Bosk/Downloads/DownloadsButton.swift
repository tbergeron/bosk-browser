import AppKit

/// The top bar button for downloads. It shows only when there are downloads, and it
/// opens a list with progress and "Show in Finder".
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
        if popover.isShown { popover.contentViewController = DownloadsList() }
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
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for item in DownloadManager.shared.items.prefix(10) {
            stack.addArrangedSubview(row(for: item))
        }
        if DownloadManager.shared.items.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "No downloads"))
        }
        view = stack
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
            let button = NSButton(title: "Show in Finder", target: nil, action: nil)
            button.bezelStyle = .accessoryBarAction
            let destination = item.destination
            button.target = FinderRevealer.shared
            button.action = #selector(FinderRevealer.reveal(_:))
            button.identifier = NSUserInterfaceItemIdentifier(destination?.path ?? "")
            status = button
        case .failed:
            let label = NSTextField(labelWithString: "Failed")
            label.textColor = .systemRed
            status = label
        }
        return NSStackView(views: [name, status])
    }
}

@MainActor
private final class FinderRevealer: NSObject {
    static let shared = FinderRevealer()
    @objc func reveal(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
