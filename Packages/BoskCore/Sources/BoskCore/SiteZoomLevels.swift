import Foundation

/// The page zoom of each site that the user zoomed. All other sites follow the default,
/// and they go on following it when the user changes the default.
public struct SiteZoomLevels: Sendable {
    public private(set) var levels: [String: Double]

    public init(_ levels: [String: Double] = [:]) {
        self.levels = levels
    }

    public func zoom(for site: String?, defaultZoom: Double) -> Double {
        site.flatMap { levels[$0] } ?? defaultZoom
    }

    /// - Parameter zoom: Nil, or the default itself, makes the site follow the default again.
    public mutating func set(_ zoom: Double?, for site: String, defaultZoom: Double) {
        levels[site] = zoom.flatMap { abs($0 - defaultZoom) < 0.001 ? nil : $0 }
    }
}
