import AppKit

/// A popover row with a highlight under the pointer, as in menus. The highlight goes a little
/// past the row's sides, so the row content keeps the popover's edge spacing.
/// A disabled button row does not highlight.
@MainActor
final class HoverRowView: NSView {
    private let content: NSView
    private let highlight = NSView()
    private var isHovered = false
    private var monitor: Any?

    init(_ content: NSView) {
        self.content = content
        super.init(frame: .zero)
        clipsToBounds = false
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.layer?.cornerCurve = .continuous
        highlight.isHidden = true
        addSubview(highlight)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: -8, dy: 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        // A popover that is not the key window gets no mouse-moved events: the browser window
        // gets them, and tracking areas in the popover stay quiet (the extensions and downloads
        // lists). So follow the pointer in every mouse-moved event of the app.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.followPointer() }
            return event
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // For a pointer that leaves the row to outside the app, where the app gets no mouse-moved events.
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        // A row made under a pointer that does not move (the extensions list makes its rows again
        // when an extension changes).
        followPointer()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func followPointer() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        setHovered(bounds.contains(point))
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateHighlight()
    }

    private func updateHighlight() {
        let enabled = (content as? NSControl)?.isEnabled ?? true
        highlight.isHidden = !(isHovered && enabled)
        highlight.layer?.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.1))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlight()
    }
}
