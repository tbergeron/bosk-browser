import AppKit
import BoskCore
import WebKit

/// Chrome extensions through WebKit's WKWebExtension. Owns the one extension controller
/// that all tabs share, keeps the installed extensions on disk, saves their permissions
/// (WebKit does not), and answers WebKit's questions about tabs, windows and prompts.
@MainActor
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()

    let controller = WKWebExtensionController(configuration: .default())

    /// One installed extension, as saved in extensions.json.
    struct Record: Codable {
        var id: String
        /// The folder or ZIP file name in the Extensions folder.
        var fileName: String
        var enabled: Bool
        var grantedPermissions: [String: Date] = [:]
        var grantedMatchPatterns: [String: Date] = [:]
        var deniedPermissions: [String: Date] = [:]
        var deniedMatchPatterns: [String: Date] = [:]
        /// The user's own folder, for an unpacked install. Reload copies it again.
        var sourcePath: String?
    }

    private(set) var records: [Record] = []
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    /// All windows. AppDelegate sets it.
    var windowsProvider: (() -> [BrowserWindowController])?

    private let directory = Defaults.dataDirectory.appending(path: "Extensions", directoryHint: .isDirectory)
    private var registryURL: URL { directory.appending(path: "extensions.json") }

    override private init() {
        super.init()
        controller.delegate = self
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Loading

    /// Loads the enabled extensions. Call once at launch, after the windows exist.
    func loadInstalledExtensions() async {
        guard let data = try? Data(contentsOf: registryURL) else { return }
        do {
            records = try JSONDecoder().decode([Record].self, from: data)
        } catch {
            // Keep the bad file for inspection instead of writing over it later.
            let backup = registryURL.deletingPathExtension().appendingPathExtension("broken.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: registryURL, to: backup)
            NSLog("Bosk: extensions file did not load (%@). Moved it to %@.", "\(error)", backup.path)
            return
        }
        await unpackOldZipInstalls()
        for record in records where record.enabled {
            do {
                try await load(record)
            } catch {
                NSLog("Bosk: extension %@ did not load: %@", record.fileName, "\(error)")
            }
        }
        changed()
    }

    /// Earlier installs kept the ZIP file. WebKit unpacks a ZIP on every load, on the main
    /// thread (about 1 s for uBlock Origin Lite), so unpack it one time into a folder.
    private func unpackOldZipInstalls() async {
        for index in records.indices where records[index].fileName.hasSuffix(".zip") {
            let zip = directory.appending(path: records[index].fileName)
            let folderName = String(records[index].fileName.dropLast(4))
            do {
                try await Self.unpack(zip, to: directory.appending(path: folderName))
                try? FileManager.default.removeItem(at: zip)
                records[index].fileName = folderName
            } catch {
                NSLog("Bosk: could not unpack %@: %@", zip.path, "\(error)")
            }
        }
        saveRegistry()
    }

    /// Unpacks a ZIP archive with ditto, off the main thread.
    private static func unpack(_ zip: URL, to folder: URL) async throws {
        try? FileManager.default.removeItem(at: folder)
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, folder.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: folder)
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: zip.path])
            }
            // A ZIP can hold symbolic links. A link could let the extension read or write files
            // outside its folder, and extensions do not need links, so refuse the archive.
            let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
            while let item = items?.nextObject() as? URL {
                guard try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    try? FileManager.default.removeItem(at: folder)
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: zip.path])
                }
            }
        }.value
    }

    private func load(_ record: Record) async throws {
        let webExtension = try await WKWebExtension(resourceBaseURL: directory.appending(path: record.fileName))
        let context = WKWebExtensionContext(for: webExtension)
        // A stable ID keeps the extension's storage and its chrome-extension:// origin.
        context.uniqueIdentifier = record.id
        context.grantedPermissions = Self.permissions(record.grantedPermissions)
        context.deniedPermissions = Self.permissions(record.deniedPermissions)
        context.grantedPermissionMatchPatterns = Self.patterns(record.grantedMatchPatterns)
        context.deniedPermissionMatchPatterns = Self.patterns(record.deniedMatchPatterns)
        #if DEBUG
        context.isInspectable = true
        #endif
        try controller.load(context)
        contexts[record.id] = context
    }

    // MARK: Installing

    /// Installs from an unpacked folder, a .zip file, or a .crx file.
    func install(from source: URL, in window: NSWindow?) async throws {
        let id = UUID().uuidString
        let fileName: String
        var sourcePath: String?
        if source.hasDirectoryPath {
            fileName = id
            sourcePath = source.path
            try FileManager.default.copyItem(at: source, to: directory.appending(path: fileName))
        } else {
            fileName = id
            try await unpackArchive(Data(contentsOf: source), into: fileName)
        }
        try await finishInstall(Record(id: id, fileName: fileName, enabled: true, sourcePath: sourcePath), in: window)
    }

    /// Copies an unpacked extension's folder again, so changes the user made in it take effect.
    /// Keeps the ID, so storage and permissions stay.
    func reload(id: String) async throws {
        saveRegistry() // The record then has the permissions granted since launch.
        guard let record = records.first(where: { $0.id == id }), let sourcePath = record.sourcePath else { return }
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        unload(id)
        let installed = directory.appending(path: record.fileName)
        try? FileManager.default.removeItem(at: installed)
        try FileManager.default.copyItem(at: source, to: installed)
        if record.enabled { try await load(record) }
        changed()
    }

    /// Installs a Chrome Web Store extension (a user click on "Add to Bosk").
    func installFromWebStore(extensionID: String, in window: NSWindow?) async throws {
        guard let url = ChromeExtensionPackage.downloadURL(forExtensionID: extensionID) else { return }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChromeExtensionPackage.Error.notAnExtension
        }
        // A new folder, so the installed copy stays until the user says yes.
        let fileName = UUID().uuidString
        try await unpackArchive(data, into: fileName)
        try await finishInstall(Record(id: extensionID, fileName: fileName, enabled: true), in: window)
    }

    /// Writes the ZIP inside a CRX (or a plain ZIP) to a temporary file and unpacks it.
    private func unpackArchive(_ data: Data, into folderName: String) async throws {
        let zip = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".zip")
        try ChromeExtensionPackage.zipArchive(from: data).write(to: zip)
        defer { try? FileManager.default.removeItem(at: zip) }
        try await Self.unpack(zip, to: directory.appending(path: folderName))
    }

    /// Shows what the extension asks for. "Add" grants it all, as Chrome does at install.
    private func finishInstall(_ record: Record, in window: NSWindow?) async throws {
        let webExtension = try await WKWebExtension(resourceBaseURL: directory.appending(path: record.fileName))
        let summary = PermissionText.summary(permissions: webExtension.requestedPermissions,
                                             patterns: webExtension.allRequestedMatchPatterns)
        let name = webExtension.displayName ?? "This extension"
        guard await ExtensionPrompts.confirm(title: "Add “\(name)”?", message: summary,
                                             confirmTitle: "Add Extension", in: window) else {
            try? FileManager.default.removeItem(at: directory.appending(path: record.fileName))
            return
        }
        // The store ID is the record ID, so a second install replaces the first.
        if let existing = records.firstIndex(where: { $0.id == record.id }) {
            unload(record.id)
            try? FileManager.default.removeItem(at: directory.appending(path: records[existing].fileName))
            records.remove(at: existing)
        }
        var record = record
        let now = Date.distantFuture
        record.grantedPermissions = Self.dictionary(webExtension.requestedPermissions.map { ($0.rawValue, now) })
        record.grantedMatchPatterns = Self.dictionary(webExtension.allRequestedMatchPatterns.map { ($0.string, now) })
        records.append(record)
        try await load(record)
        saveRegistry()
        changed()
    }

    func setEnabled(_ enabled: Bool, id: String) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].enabled = enabled
        if enabled { try? await load(records[index]) } else { unload(id) }
        saveRegistry()
        changed()
    }

    func remove(id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        unload(id)
        try? FileManager.default.removeItem(at: directory.appending(path: records[index].fileName))
        records.remove(at: index)
        saveRegistry()
        changed()
    }

    private func unload(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
    }

    // MARK: Saving

    /// Saves granted and denied permissions of loaded extensions.
    func saveRegistry() {
        for (index, record) in records.enumerated() {
            guard let context = contexts[record.id] else { continue }
            records[index].grantedPermissions = Self.dictionary(context.grantedPermissions.map { ($0.key.rawValue, $0.value) })
            records[index].deniedPermissions = Self.dictionary(context.deniedPermissions.map { ($0.key.rawValue, $0.value) })
            records[index].grantedMatchPatterns = Self.dictionary(context.grantedPermissionMatchPatterns.map { ($0.key.string, $0.value) })
            records[index].deniedMatchPatterns = Self.dictionary(context.deniedPermissionMatchPatterns.map { ($0.key.string, $0.value) })
        }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    /// Two patterns can have the same text; `uniqueKeysWithValues` would stop the app.
    private static func dictionary(_ pairs: [(String, Date)]) -> [String: Date] {
        Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    private static func permissions(_ saved: [String: Date]) -> [WKWebExtension.Permission: Date] {
        Dictionary(uniqueKeysWithValues: saved.map { (WKWebExtension.Permission(rawValue: $0.key), $0.value) })
    }

    private static func patterns(_ saved: [String: Date]) -> [WKWebExtension.MatchPattern: Date] {
        var result: [WKWebExtension.MatchPattern: Date] = [:]
        for (text, date) in saved {
            if let pattern = try? WKWebExtension.MatchPattern(string: text) { result[pattern] = date }
        }
        return result
    }

    // MARK: Observers (toolbar buttons, settings)

    func addObserver(_ owner: AnyObject, _ handler: @escaping () -> Void) {
        observers[ObjectIdentifier(owner)] = handler
    }

    func removeObserver(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
    }

    /// Also called when the top bar order or pins change, so each window's bar reloads.
    func changed() {
        observers.values.forEach { $0() }
    }

    var loadedContexts: [WKWebExtensionContext] {
        records.compactMap { contexts[$0.id] }
    }

    // MARK: Tab and window events (from TabStore and the window controllers)

    func didOpen(_ tab: Tab) { controller.didOpenTab(tab) }

    func didClose(_ tab: Tab, windowIsClosing: Bool = false) {
        controller.didCloseTab(tab, windowIsClosing: windowIsClosing)
    }

    func didActivate(_ tab: Tab, previous: Tab?) {
        controller.didActivateTab(tab, previousActiveTab: previous)
        controller.didSelectTabs([tab])
        if let previous { controller.didDeselectTabs([previous]) }
    }

    /// - Parameter oldWindow: The window the tab came from, when it moved to another window.
    func didMove(_ tab: Tab, from index: Int, in oldWindow: BrowserWindowController? = nil) {
        controller.didMoveTab(tab, from: index, in: oldWindow ?? tab.store?.windowController)
    }

    func didChange(_ properties: WKWebExtension.TabChangedProperties, for tab: Tab) {
        controller.didChangeTabProperties(properties, for: tab)
    }
}

/// Plain words for what an extension asks for.
@MainActor
enum PermissionText {
    static func summary(permissions: Set<WKWebExtension.Permission>, patterns: Set<WKWebExtension.MatchPattern>) -> String {
        var lines: [String] = []
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            lines.append("• Read and change data on all websites")
        } else if !patterns.isEmpty {
            // A pattern with no host (file:///*) shows as written.
            lines.append("• Read and change data on: " + list(Set(patterns.map { $0.host ?? $0.string }).sorted()))
        }
        let names = permissions.map(\.rawValue).sorted()
        if !names.isEmpty { lines.append("• Use: " + names.joined(separator: ", ")) }
        return lines.isEmpty ? "It asks for no special access." : "It can:\n" + lines.joined(separator: "\n")
    }

    /// The first 5 names, and how many more, so the user knows the list is not complete.
    static func list(_ names: [String]) -> String {
        let shown = names.prefix(5).joined(separator: ", ")
        return names.count > 5 ? shown + ", and \(names.count - 5) more" : shown
    }
}

/// Alerts for extension questions. Shown as a sheet on the window when there is one.
@MainActor
enum ExtensionPrompts {
    static func confirm(title: String, message: String, confirmTitle: String, in window: NSWindow?) async -> Bool {
        #if DEBUG
        // Tests: `-BoskAcceptExtensionPrompts YES` answers yes without a sheet.
        if UserDefaults.standard.bool(forKey: "BoskAcceptExtensionPrompts") { return true }
        #endif
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        if let window { return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
