import Foundation
import os

/// Every fixed value in Bosk. Bosk is opinionated: change a value here, not in a settings screen.
enum Defaults {
    static let initialWindowSize = CGSize(width: 1280, height: 820)
    static let minimumWindowSize = CGSize(width: 640, height: 400)

    static let searchURL = URL(string: "https://www.google.com/search")!

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
    static let tabSleepIdleLimit: TimeInterval = debugOverride("BoskSleepAfterSeconds") ?? 60 * 60
    /// Idle time before sleep when macOS reports memory pressure.
    static let tabSleepPressureIdleLimit: TimeInterval = 5 * 60
    static let tabSleepCheckInterval: TimeInterval = min(60, tabSleepIdleLimit / 2)
    /// Width in points of the page picture shown while a sleeping tab wakes.
    static let snapshotWidth: CGFloat = 900

    static let topBarHeight: CGFloat = 44
    static let sidebarWidth: CGFloat = 250
    /// Folded sidebar. Wide enough for the three window buttons.
    static let stripWidth: CGFloat = 76
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
