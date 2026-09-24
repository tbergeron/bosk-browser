import AppKit
import Sparkle

/// Sparkle updates. Off until the build has a feed URL and a public key (docs/release.md),
/// so development builds never check for updates.
///
/// Sparkle checks once a day. When it finds an update, the top bar shows an "Update available"
/// button instead of Sparkle's window. The user can dismiss the button; it comes back after 24 hours.
@MainActor
enum Updater {
    private static var controller: SPUStandardUpdaterController?
    private static let reminder = UpdateReminder()
    private static let remindAfterKey = "BoskUpdateRemindAfter"
    private static let remindInterval: TimeInterval = 24 * 60 * 60

    /// Sparkle found an update that the user did not look at yet.
    fileprivate static var hasPendingUpdate = false { didSet { refresh() } }
    private static var reminderTimer: Timer?

    /// Posted when `showsUpdateButton` changes.
    static let updateButtonDidChange = Notification.Name("BoskUpdateButtonDidChange")

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    static var showsUpdateButton: Bool { hasPendingUpdate && !isDismissed }

    /// Dismissed less than 24 hours ago. A date in defaults, so a relaunch does not bring the button back early.
    private static var isDismissed: Bool {
        guard let date = UserDefaults.standard.object(forKey: remindAfterKey) as? Date else { return false }
        return date > Date()
    }

    static func start() {
        guard isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: reminder)
    }

    /// Also brings a found update's window to the front.
    static func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    static func dismissUpdateButton() {
        UserDefaults.standard.set(Date().addingTimeInterval(remindInterval), forKey: remindAfterKey)
        refresh()
    }

    private static func refresh() {
        // Hourly while dismissed. A timer does not count time while the Mac sleeps,
        // so one 24-hour timer can be late by the time the Mac slept.
        if hasPendingUpdate && isDismissed {
            if reminderTimer == nil {
                reminderTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
                    MainActor.assumeIsolated { refresh() }
                }
            }
        } else {
            reminderTimer?.invalidate()
            reminderTimer = nil
        }
        NotificationCenter.default.post(name: updateButtonDidChange, object: nil)
    }
}

/// Sparkle's "gentle reminders": Bosk shows scheduled updates itself, in the top bar.
/// https://sparkle-project.org/documentation/gentle-reminders
@MainActor
private final class UpdateReminder: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate { Updater.hasPendingUpdate = true }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Updater.hasPendingUpdate = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        Updater.hasPendingUpdate = false
    }
}

/// "Update available" and its dismiss button, in the top bar when Sparkle found an update.
@MainActor
final class UpdateButton: NSView {
    private let button = NSButton(title: "Update available", target: nil, action: nil)
    private let dismissButton = NSButton()
    private let dismissWidth: CGFloat = 16

    init() {
        super.init(frame: .zero)
        button.bezelStyle = .push
        button.controlSize = .small
        button.target = self
        button.action = #selector(updateClicked)
        button.toolTip = "Show the update"
        addSubview(button)
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss Update")
        dismissButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        dismissButton.isBordered = false
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.toolTip = "Remind me in 24 hours"
        addSubview(dismissButton)
        isHidden = !Updater.showsUpdateButton
        NotificationCenter.default.addObserver(forName: Updater.updateButtonDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isHidden = !Updater.showsUpdateButton
                self?.superview?.needsLayout = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var fittingSize: NSSize {
        guard !isHidden else { return .zero }
        let size = button.fittingSize
        return NSSize(width: size.width + dismissWidth, height: size.height)
    }

    override func layout() {
        super.layout()
        let size = button.fittingSize
        button.frame = NSRect(x: 0, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        dismissButton.frame = NSRect(x: button.frame.maxX, y: bounds.midY - 8, width: dismissWidth, height: 16)
    }

    @objc private func updateClicked() { Updater.checkForUpdates() }
    @objc private func dismissClicked() { Updater.dismissUpdateButton() }
}
