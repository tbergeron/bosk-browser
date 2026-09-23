import AppKit
import BoskCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The Settings window: a list of panes on the left, cards of settings on the right.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: .init())))
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate()
    }
}

/// State for the settings view, read from Bosk's stores.
@MainActor
@Observable
final class SettingsModel {
    struct ExtensionRow: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
        /// "Version 1.2 · Chrome Web Store · 1 warning"
        let details: String
        let canReload: Bool
        var enabled: Bool
    }

    var isDefaultBrowser = false
    var defaultZoom = PageZoom.defaultZoom
    var appearance = Preferences.appearance
    var correctsSpelling = Preferences.correctsSpelling
    var sleepsTabs = Preferences.sleepsTabs
    var downloadFolder = Preferences.downloadFolder
    var asksWhereToSave = Preferences.asksWhereToSave
    var extensions: [ExtensionRow] = []
    var storeInput = ""
    var message: String?

    var storeExtensionID: String? { ChromeExtensionPackage.extensionID(fromUserInput: storeInput) }

    init() {
        refresh()
        ExtensionManager.shared.addObserver(self) { [weak self] in self?.refresh() }
    }

    func refresh() {
        isDefaultBrowser = Self.checkDefaultBrowser()
        downloadFolder = Preferences.downloadFolder
        extensions = ExtensionManager.shared.records.map { record in
            let webExtension = ExtensionManager.shared.contexts[record.id]?.webExtension
            let fromStore = ChromeExtensionPackage.isExtensionID(record.id)
            var details: [String] = []
            if let version = webExtension?.version { details.append("Version \(version)") }
            details.append(fromStore ? "Chrome Web Store" : "Unpacked")
            let warnings = webExtension?.errors.count ?? 0
            if warnings > 0 { details.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
            return ExtensionRow(id: record.id,
                                name: webExtension?.displayName ?? record.fileName,
                                icon: webExtension?.icon(for: CGSize(width: 32, height: 32)),
                                details: details.joined(separator: " · "),
                                canReload: record.sourcePath != nil,
                                enabled: record.enabled)
        }
    }

    // MARK: General

    private static func checkDefaultBrowser() -> Bool {
        guard let web = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: web) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks macOS to use Bosk for http and https links. macOS shows its own confirmation.
    func makeDefaultBrowser() async {
        do {
            for scheme in ["http", "https"] {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                                   toOpenURLsWithScheme: scheme)
            }
            message = nil
        } catch {
            message = "macOS did not change the default browser: \(error.localizedDescription)"
        }
        refresh()
    }

    func setDefaultZoom(_ zoom: Double) {
        PageZoom.defaultZoom = zoom
        defaultZoom = zoom
    }

    func setAppearance(_ value: Preferences.Appearance) {
        Preferences.appearance = value
        appearance = value
    }

    func setCorrectsSpelling(_ value: Bool) {
        Preferences.correctsSpelling = value
        correctsSpelling = value
    }

    // MARK: Tabs

    func setSleepsTabs(_ value: Bool) {
        Preferences.sleepsTabs = value
        sleepsTabs = value
    }

    // MARK: Extensions

    func addFromStore() {
        guard let id = storeExtensionID else { return }
        let window = SettingsWindowController.shared.window
        Task {
            do {
                try await ExtensionManager.shared.installFromWebStore(extensionID: id, in: window)
                storeInput = ""
                message = nil
            } catch {
                message = "The extension did not install: \(error.localizedDescription)"
            }
        }
    }

    func openStore() {
        open(URL(string: "https://chromewebstore.google.com")!)
    }

    func addExtension() {
        let panel = NSOpenPanel()
        panel.message = "Choose an unpacked extension folder, or a .zip or .crx file."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip, UTType(filenameExtension: "crx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await ExtensionManager.shared.install(from: url, in: nil)
                message = nil
            } catch {
                message = "The extension did not install: \(error.localizedDescription)"
            }
        }
    }

    func setEnabled(_ enabled: Bool, id: String) {
        Task { await ExtensionManager.shared.setEnabled(enabled, id: id) }
    }

    func reload(id: String) {
        Task {
            do {
                try await ExtensionManager.shared.reload(id: id)
                message = nil
            } catch {
                message = "The extension did not reload: \(error.localizedDescription)"
            }
        }
    }

    func remove(id: String) {
        ExtensionManager.shared.remove(id: id)
    }

    // MARK: Downloads

    func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = downloadFolder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Preferences.downloadFolder = url
        downloadFolder = Preferences.downloadFolder
    }

    func setAsksWhereToSave(_ value: Bool) {
        Preferences.asksWhereToSave = value
        asksWhereToSave = value
    }

    // MARK: Privacy

    func clearHistory() {
        guard confirm("Clear all history?", "Command bar suggestions forget every page you visited.",
                      button: "Clear History") else { return }
        Task {
            await HistoryStore.shared.clear()
            message = "History cleared."
        }
    }

    /// Removes all website data except the cache: cookies, local storage, databases.
    func signOutOfEverything() {
        guard confirm("Sign out of every site?", "Bosk removes all cookies and website data.",
                      button: "Sign Out") else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes().subtracting(Self.cacheTypes)
        Task {
            await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast)
            message = "Signed out of every site."
        }
    }

    func clearCache() {
        Task {
            await WKWebsiteDataStore.default().removeData(ofTypes: Self.cacheTypes, modifiedSince: .distantPast)
            message = "Cache cleared."
        }
    }

    private static let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                                  WKWebsiteDataTypeFetchCache]

    private func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: About

    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    func checkForUpdates() { Updater.checkForUpdates() }

    /// A new GitHub issue with the versions filled in. Nothing personal goes in it.
    func sendFeedback() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        var components = URLComponents(url: Defaults.projectURL.appending(path: "issues/new"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "body", value: "\n\n---\nBosk \(version) (\(build)), macOS \(macOS)")]
        if let url = components?.url { open(url) }
    }

    /// Opens a page in a new tab of a browser window.
    private func open(_ url: URL) {
        (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [url])
    }
}
