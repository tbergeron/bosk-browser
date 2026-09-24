import AppKit
import BoskCore

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

    /// Tab group colors, in pastel tones. A little deeper in light appearance, so titles stay readable.
    static func group(_ color: TabGroupColor) -> NSColor {
        let (light, dark): (UInt32, UInt32) = switch color {
        case .grey: (0x8E949B, 0xC9CCD1)
        case .blue: (0x6F9BE8, 0xA8C7FA)
        case .red: (0xE08279, 0xF4A7A1)
        case .yellow: (0xD4AC3C, 0xF8DE8A)
        case .green: (0x6DB57E, 0xA8D8B0)
        case .pink: (0xDE7FB3, 0xF6A8D0)
        case .purple: (0xA983E3, 0xD2B3F7)
        case .cyan: (0x5BB8C6, 0x9EDDE8)
        case .orange: (0xE59B5F, 0xF9C49A)
        }
        return NSColor(name: nil) { appearance in rgb(appearance.isDark ? dark : light) }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
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
