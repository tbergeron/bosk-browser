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

    /// A background tab sleeps after this idle time (see SleepPolicy).
    static let tabSleepIdleLimit: TimeInterval = debugOverride("BoskSleepAfterSeconds") ?? 30 * 60
    /// Idle time before sleep when macOS reports memory pressure.
    static let tabSleepPressureIdleLimit: TimeInterval = 5 * 60
    static let tabSleepCheckInterval: TimeInterval = min(60, tabSleepIdleLimit / 2)
    /// Width in points of the page picture shown while a sleeping tab wakes.
    static let snapshotWidth: CGFloat = 900

    static let topBarHeight: CGFloat = 44
    /// The open sidebar's width until the user drags its edge (see Preferences.sidebarWidth).
    static let sidebarWidth: CGFloat = 250
    static let minimumSidebarWidth: CGFloat = 180
    static let maximumSidebarWidth: CGFloat = 420
    /// A drag of the sidebar edge to the left of this folds the sidebar into the strip;
    /// a drag of the strip edge to the right of it opens the sidebar again.
    static let sidebarFoldDragWidth: CGFloat = 130
    /// Folded sidebar. The window buttons are wider: the top bar makes room for the rest.
    static let stripWidth: CGFloat = 57
    static let sidebarHeaderHeight: CGFloat = 44
    static let tabRowHeight: CGFloat = 34
    /// Space around the web content card.
    static let contentInset: CGFloat = 8
    static let contentCornerRadius: CGFloat = 10
    static let commandBarWidth: CGFloat = 640
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
