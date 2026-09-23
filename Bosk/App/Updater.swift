import AppKit
import Sparkle

/// Sparkle updates. Off until the build has a feed URL and a public key (docs/release.md),
/// so development builds never check for updates.
@MainActor
enum Updater {
    private static var controller: SPUStandardUpdaterController?

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    static func start() {
        guard isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    static func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
