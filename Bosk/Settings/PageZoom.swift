import Foundation
import WebKit

/// Page zoom: one default for all pages (a setting), and Cmd+= / Cmd+- / Cmd+0 per tab.
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
            NotificationCenter.default.post(name: didChangeDefault, object: nil)
        }
    }

    /// Posted when the default changes; open tabs take the new default.
    static let didChangeDefault = Notification.Name("BoskDefaultPageZoomDidChange")

    static func next(after zoom: Double, larger: Bool) -> Double {
        if larger { return steps.first { $0 > zoom + 0.001 } ?? steps.last! }
        return steps.last { $0 < zoom - 0.001 } ?? steps.first!
    }

    static func label(_ zoom: Double) -> String {
        "\(Int((zoom * 100).rounded())) %"
    }
}
