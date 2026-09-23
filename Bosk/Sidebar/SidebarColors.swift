import AppKit

/// Colors for sidebar rows and tiles, for light and dark appearance.
enum SidebarColors {
    /// The window background around the content card. A solid color, not a blur:
    /// it costs nothing to draw while the sidebar animates.
    static let background = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1)
                          : NSColor(srgbRed: 0.90, green: 0.88, blue: 0.88, alpha: 1)
    }
    static let selected = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.75)
    }
    static let hover = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.white.withAlphaComponent(0.4)
    }
    static let tile = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.05)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSView {
    /// Resolves a dynamic color for this view's appearance (for CALayer colors).
    func resolved(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
}
