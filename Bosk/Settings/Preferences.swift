import AppKit

/// The choices in Settings, saved in UserDefaults. Fixed values stay in `Defaults`.
@MainActor
enum Preferences {
    enum Appearance: String, CaseIterable {
        case light, dark, system
    }

    private static let appearanceKey = "BoskAppearance"
    /// WebKit's own key: it reads it for autocorrect in pages.
    private static let spellingKey = "WebAutomaticSpellingCorrectionEnabled"
    private static let sleepsTabsKey = "BoskSleepsTabs"
    private static let downloadFolderKey = "BoskDownloadFolder"
    private static let asksWhereToSaveKey = "BoskAsksWhereToSave"
    private static let sidebarWidthKey = "BoskSidebarWidth"
    private static let extensionOrderKey = "BoskExtensionOrder"
    private static let unpinnedExtensionsKey = "BoskUnpinnedExtensions"
    private static let blocksAdsKey = "BoskBlocksAds"
    private static let adsAllowedSitesKey = "BoskAdsAllowedSites"

    static var appearance: Appearance {
        get { UserDefaults.standard.string(forKey: appearanceKey).flatMap(Appearance.init) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey)
            applyAppearance()
        }
    }

    /// Windows and web pages (`prefers-color-scheme`) follow the app appearance.
    static func applyAppearance() {
        NSApp.appearance = switch appearance {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }

    /// When the user never chose, WebKit uses the macOS setting.
    static var correctsSpelling: Bool {
        get { UserDefaults.standard.object(forKey: spellingKey) as? Bool ?? NSSpellChecker.isAutomaticSpellingCorrectionEnabled }
        set { UserDefaults.standard.set(newValue, forKey: spellingKey) }
    }

    static var sleepsTabs: Bool {
        get { UserDefaults.standard.object(forKey: sleepsTabsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: sleepsTabsKey) }
    }

    /// ~/Downloads when the user never chose, or when the chosen folder is gone.
    static var downloadFolder: URL {
        get {
            var isDirectory: ObjCBool = false
            if let path = UserDefaults.standard.string(forKey: downloadFolderKey),
               FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return .downloadsDirectory
        }
        set { UserDefaults.standard.set(newValue.path, forKey: downloadFolderKey) }
    }

    /// The built-in ad blocker (AdBlocker). On when the user never chose.
    static var blocksAds: Bool {
        get { UserDefaults.standard.object(forKey: blocksAdsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: blocksAdsKey) }
    }

    /// Sites where the user allows ads (see AdBlocker.site(for:)).
    static var adsAllowedSites: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: adsAllowedSitesKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: adsAllowedSitesKey) }
    }

    static var asksWhereToSave: Bool {
        get { UserDefaults.standard.bool(forKey: asksWhereToSaveKey) }
        set { UserDefaults.standard.set(newValue, forKey: asksWhereToSaveKey) }
    }

    /// The open sidebar's width. The user sets it with a drag on the sidebar edge.
    static var sidebarWidth: CGFloat {
        get {
            let width = UserDefaults.standard.double(forKey: sidebarWidthKey)
            return width > 0 ? width : Defaults.sidebarWidth
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: sidebarWidthKey) }
    }

    /// Extension IDs in the user's top bar order (see ExtensionToolbarOrder).
    static var extensionOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: extensionOrderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: extensionOrderKey) }
    }

    /// Extensions that do not show in the top bar. They show in the extensions list only.
    static var unpinnedExtensions: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: unpinnedExtensionsKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: unpinnedExtensionsKey) }
    }
}
