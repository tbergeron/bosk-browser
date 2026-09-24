import Foundation
import os

/// Every fixed value in Bosk. The few user choices are in `Preferences`; the rest is fixed here.
enum Defaults {
    static let initialWindowSize = CGSize(width: 1280, height: 820)
    static let minimumWindowSize = CGSize(width: 640, height: 400)

    /// Session, history and extensions. Debug builds use their own folder (and their own
    /// bundle ID, see project.yml), so development never changes the data of the installed app.
    #if DEBUG
    static let dataDirectory = URL.applicationSupportDirectory.appending(path: "Bosk Debug", directoryHint: .isDirectory)
    #else
    static let dataDirectory = URL.applicationSupportDirectory.appending(path: "Bosk", directoryHint: .isDirectory)
    #endif

    static let searchURL = URL(string: "https://www.google.com/search")!
    static let projectURL = URL(string: "https://github.com/tbergeron/bosk-browser")!

    /// Added to WebKit's user agent. Some sites block browsers they do not know,
    /// so Bosk says it is the Safari version installed on this Mac.
    static let userAgentApplicationName: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let info = NSDictionary(contentsOf: plist)
        let version = info?["CFBundleShortVersionString"] as? String ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    static let sessionSaveDelay: Duration = .seconds(2)

    /// Debug builds only: replaces the idle time chosen in Settings (Preferences.tabSleepAfter).
    static let tabSleepIdleLimitOverride: TimeInterval? = debugOverride("BoskSleepAfterSeconds")
    /// Idle time before sleep when macOS reports memory pressure.
    static let tabSleepPressureIdleLimit: TimeInterval = 5 * 60
    static let tabSleepCheckInterval: TimeInterval = min(60, (tabSleepIdleLimitOverride ?? 60 * 60) / 2)
    /// Reloads of the selected tab after its page process stops, in one minute.
    static let crashReloadLimit = 3
    /// Saved reader articles older than this are deleted at launch.
    static let readerArticleLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// The ad blocker's filter lists: ads, then trackers.
    static let adListURLs = [URL(string: "https://easylist.to/easylist/easylist.txt")!,
                             URL(string: "https://easylist.to/easylist/easyprivacy.txt")!]
    /// The ad blocker downloads its lists again after this time.
    static let adListUpdateInterval: TimeInterval = 7 * 24 * 60 * 60
    /// Sites where the ad blocker is off until the user changes the per-site switch.
    /// EasyPrivacy breaks the Apple Account sign-in form on appleid.apple.com.
    static let adsAllowedSites: Set<String> = ["appleid.apple.com"]

    /// Sidebar open: the window buttons are centered in this height.
    static let titleBarHeight: CGFloat = 48
    /// The top bar in the card. Open, the card starts `contentInset` below the window top, so this
    /// height keeps the top bar buttons on the same line as the window buttons. Folded, the card
    /// starts at the window top, and its top bar is `contentInset` taller, so the page starts at the same height.
    static let topBarHeight: CGFloat = titleBarHeight - 2 * contentInset
    /// The open sidebar's width until the user drags its edge (see Preferences.sidebarWidth).
    static let sidebarWidth: CGFloat = 250
    static let minimumSidebarWidth: CGFloat = 180
    static let maximumSidebarWidth: CGFloat = 420
    /// A drag of the sidebar edge to the left of this folds the sidebar into the strip;
    /// a drag of the strip edge to the right of it opens the sidebar again.
    static let sidebarFoldDragWidth: CGFloat = 130
    /// Folded sidebar. The window buttons are wider: the top bar makes room for the rest.
    static let stripWidth: CGFloat = 57
    static let sidebarHeaderHeight: CGFloat = titleBarHeight
    static let tabRowHeight: CGFloat = 34
    /// Space around the web content card.
    static let contentInset: CGFloat = 8
    static let contentCornerRadius: CGFloat = 10
    static let commandBarWidth: CGFloat = 640
    /// The command bar lists scroll after this many rows.
    static let commandBarMaxVisibleRows = 10
    static let sidebarAnimationDuration: TimeInterval = 0.28
}

/// Debug builds only: a value from the command line (for example `-BoskSleepAfterSeconds 10`),
/// so tests do not wait an hour. Release builds always use the fixed value.
private func debugOverride(_ key: String) -> Double? {
    #if DEBUG
    let value = UserDefaults.standard.double(forKey: key)
    return value > 0 ? value : nil
    #else
    return nil
    #endif
}

/// Signpost intervals for Instruments ("Points of Interest"), so hitches can be matched
/// to Bosk UI work (sidebar fold, tab switch).
let performanceSignposter = OSSignposter(subsystem: "app.bosk", category: .pointsOfInterest)
