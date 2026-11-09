import BoskCore
import Foundation
import WebKit

/// Page zoom: one default for all pages (a setting), and a saved level for each site
/// that the user zoomed (Cmd+= / Cmd+- / Cmd+0, or the site panel).
@MainActor
enum PageZoom {
    /// The zoom steps, the same as Safari's.
    static let steps: [Double] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]
    /// The choices in Settings.
    static let defaultChoices: [Double] = [0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2]
    private static let key = "BoskDefaultPageZoom"

    static var defaultZoom: Double {
        get {
            let value = UserDefaults.standard.double(forKey: key)
            return value > 0 ? value : 1
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Posted when the default or a site's level changes; open tabs take the new zoom.
    static let didChange = Notification.Name("BoskPageZoomDidChange")

    private static let sitesKey = "BoskSitePageZooms"
    private static var saved = SiteZoomLevels(UserDefaults.standard.dictionary(forKey: sitesKey) as? [String: Double] ?? [:])
    /// The levels of the private windows: the saved levels, with the changes made in a
    /// private window. Nil when there is no change. In memory only.
    private static var privateLevels: SiteZoomLevels?

    /// Pages without a site (a local file) share one level for each scheme.
    private static func site(for url: URL?) -> String? {
        ContentBlocker.site(for: url) ?? url?.scheme
    }

    static func zoom(for url: URL?, isPrivate: Bool) -> Double {
        (isPrivate ? privateLevels ?? saved : saved).zoom(for: site(for: url), defaultZoom: defaultZoom)
    }

    /// - Parameter zoom: Nil makes the site follow the default again.
    static func set(_ zoom: Double?, for url: URL?, isPrivate: Bool) {
        guard let site = site(for: url) else { return }
        if isPrivate {
            var levels = privateLevels ?? saved
            levels.set(zoom, for: site, defaultZoom: defaultZoom)
            privateLevels = levels
        } else {
            saved.set(zoom, for: site, defaultZoom: defaultZoom)
            UserDefaults.standard.set(saved.levels, forKey: sitesKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The last private window closed: private windows forget their changes.
    static func endPrivateSession() { privateLevels = nil }

    static func next(after zoom: Double, larger: Bool) -> Double {
        if larger { return steps.first { $0 > zoom + 0.001 } ?? steps.last! }
        return steps.last { $0 < zoom - 0.001 } ?? steps.first!
    }

    static func label(_ zoom: Double) -> String {
        "\(Int((zoom * 100).rounded())) %"
    }
}
