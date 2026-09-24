import AppKit
import SecurityInterface
import WebKit

/// The sliders button before the ad blocker shield, on web pages. It opens the site panel: the connection,
/// the camera and microphone answers, sound, and a button that clears the site's data.
@MainActor
final class SiteButton: NSButton {
    private let popover = NSPopover()
    private weak var tab: Tab?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Site Settings")
        symbolConfiguration = .init(pointSize: 14, weight: .medium)
        isBordered = false
        refusesFirstResponder = true
        contentTintColor = .secondaryLabelColor
        toolTip = "Site Settings"
        target = self
        action = #selector(toggle)
        popover.behavior = .transient
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var fittingSize: NSSize { isHidden ? .zero : NSSize(width: 28, height: 28) }

    func update(for tab: Tab?) {
        // The panel is about one page. It must not stay open on another tab or site.
        if tab !== self.tab || tab?.url?.host() != self.tab?.url?.host() { popover.close() }
        self.tab = tab
        isHidden = !["http", "https"].contains(tab?.url?.scheme ?? "")
        superview?.needsLayout = true
    }

    @objc private func toggle() {
        if popover.isShown { return popover.close() }
        guard let tab, let host = tab.url?.host() else { return }
        popover.contentViewController = SitePanel(tab: tab, host: host) { [weak self] in self?.popover.close() }
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

/// The popover content.
@MainActor
private final class SitePanel: NSViewController {
    private let tab: Tab
    private let host: String
    private let close: () -> Void
    private let clearButton = NSButton()
    /// The site's cookies and data. The clear button is on only when there is some.
    private var records: [WKWebsiteDataRecord] = []
    private static let width: CGFloat = 240

    init(tab: Tab, host: String, close: @escaping () -> Void) {
        self.tab = tab
        self.host = host
        self.close = close
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.addArrangedSubview(connectionRow())
        stack.addArrangedSubview(Self.separator())
        // Only the devices the site asked for.
        for device in PermissionMemory.Device.allCases {
            guard let allowed = PermissionMemory.shared.answer(for: host, device: device) else { continue }
            let (symbol, title) = device == .camera ? ("video", "Camera") : ("mic", "Microphone")
            stack.addArrangedSubview(switchRow(symbol, title, on: allowed, tag: device == .camera ? 0 : 1))
        }
        stack.addArrangedSubview(switchRow("speaker.wave.2", "Sound", on: !tab.isMuted, tag: 2))
        stack.addArrangedSubview(Self.separator())
        stack.addArrangedSubview(clearRow())
        view = stack
        // The popover takes this size. Without it, the popover is narrower than the rows.
        preferredContentSize = stack.fittingSize
        loadRecords()
    }

    // MARK: Rows

    private func connectionRow() -> NSView {
        let secure = tab.url?.scheme == "https" && tab.webView?.hasOnlySecureContent == true
        let button = Self.rowButton(secure ? "lock" : "lock.open",
                                    secure ? "Connection is Secure" : "Connection is Not Secure")
        button.contentTintColor = secure ? .systemGreen : .secondaryLabelColor
        button.toolTip = "Show Certificate"
        button.target = self
        button.action = #selector(showCertificate)
        button.isEnabled = tab.webView?.serverTrust != nil
        return HoverRowView(button)
    }

    private func switchRow(_ symbol: String, _ title: String, on: Bool, tag: Int) -> NSView {
        let toggle = NSSwitch()
        toggle.state = on ? .on : .off
        toggle.tag = tag
        toggle.target = self
        toggle.action = #selector(switchChanged(_:))
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let row = NSStackView(views: [icon, NSTextField(labelWithString: title), NSView(), toggle])
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return row
    }

    private func clearRow() -> NSView {
        // A long site name does not fit in the row. The question before the delete names the site.
        clearButton.title = "Clear Site Data…"
        clearButton.toolTip = "Clear cookies and data for \(AdBlocker.site(for: tab.url) ?? host)"
        clearButton.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        Self.style(clearButton)
        clearButton.target = self
        clearButton.action = #selector(clearData)
        clearButton.isEnabled = false
        return HoverRowView(clearButton)
    }

    private static func rowButton(_ symbol: String, _ title: String) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                              target: nil, action: nil)
        style(button)
        return button
    }

    private static func style(_ button: NSButton) {
        button.isBordered = false
        // The popover gives the keyboard focus to its first button, and the focus ring
        // makes the lock look selected.
        button.refusesFirstResponder = true
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.alignment = .left
        button.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }

    // MARK: Actions

    @objc private func switchChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        switch sender.tag {
        case 0, 1:
            let device: PermissionMemory.Device = sender.tag == 0 ? .camera : .microphone
            PermissionMemory.shared.set(on, for: host, device: device)
            guard !on else { return }
            // "Off" also stops the device in the site's open tabs. "On" works when the page asks again.
            for tab in (NSApp.delegate as? AppDelegate)?.allTabs ?? [] where tab.url?.host() == host {
                if device == .camera {
                    tab.webView?.setCameraCaptureState(.none)
                } else {
                    tab.webView?.setMicrophoneCaptureState(.none)
                }
            }
        default:
            tab.isMuted = !on
        }
    }

    @objc private func showCertificate() {
        guard let trust = tab.webView?.serverTrust, let window = tab.store?.window,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return }
        close()
        SFCertificatePanel.shared().beginSheet(for: window, modalDelegate: nil, didEnd: nil,
                                               contextInfo: nil, certificates: chain, showGroup: true)
    }

    /// WebKit keeps data per registrable domain ("google.com" for "mail.google.com").
    private func loadRecords() {
        let site = AdBlocker.site(for: tab.url) ?? host
        Task {
            let all = await WKWebsiteDataStore.default().dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            records = all.filter { site == $0.displayName || site.hasSuffix("." + $0.displayName) }
            clearButton.isEnabled = !records.isEmpty
        }
    }

    @objc private func clearData() {
        let names = records.map(\.displayName).sorted().joined(separator: ", ")
        let records = records
        let tab = tab
        close()
        let alert = NSAlert()
        alert.messageText = "Clear cookies and data for “\(names)”?"
        alert.informativeText = "You will be signed out of this site."
        alert.addButton(withTitle: "Clear Data").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
            // Show the page without the old data.
            tab.webView?.reload()
        }
    }
}

/// Mutes a page's sound. WebKit has no public API for this, so this uses the private
/// `_setPageMuted:`, as Safari does. A macOS update can remove it: then the Sound switch does nothing.
@MainActor
enum PageMute {
    private typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
    private typealias MutedState = @convention(c) (AnyObject, Selector) -> UInt
    private static let setSelector = NSSelectorFromString("_setPageMuted:")
    private static let stateSelector = NSSelectorFromString("_mediaMutedState")
    /// `_WKMediaAudioMuted`. The other bits mute the camera, microphone and screen capture.
    private static let audioMuted: UInt = 1 << 0

    // The types must be as tested, or a call with other types can crash.
    private static let setMuted: SetMuted? = implementation(setSelector, types: "v24@0:8Q16")
    private static let mutedState: MutedState? = implementation(stateSelector, types: "Q16@0:8")

    private static func implementation<T>(_ selector: Selector, types expected: String) -> T? {
        guard let method = class_getInstanceMethod(WKWebView.self, selector),
              let types = method_getTypeEncoding(method), String(cString: types) == expected else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: T.self)
    }

    static func set(_ muted: Bool, on webView: WKWebView) {
        guard let setMuted, let mutedState else { return }
        // Change only the audio bit, so a stopped camera or microphone stays stopped.
        let state = mutedState(webView, stateSelector)
        setMuted(webView, setSelector, muted ? state | audioMuted : state & ~audioMuted)
    }
}
