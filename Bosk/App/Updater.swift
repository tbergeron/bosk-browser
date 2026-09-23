import AppKit
import Sparkle

/// Sparkle updates. Off until the build has a feed URL and a public key (docs/release.md),
/// so development builds never check for updates.
///
/// Sparkle checks once a day. When it finds an update, the sidebar shows an "Update available"
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

/// Sparkle's "gentle reminders": Bosk shows scheduled updates itself, in the sidebar.
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
