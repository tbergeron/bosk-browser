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

    static var asksWhereToSave: Bool {
        get { UserDefaults.standard.bool(forKey: asksWhereToSaveKey) }
        set { UserDefaults.standard.set(newValue, forKey: asksWhereToSaveKey) }
    }
}
