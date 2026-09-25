import AppKit
import BoskCore
import WebKit

/// Chrome extensions through WebKit's WKWebExtension. Owns the one extension controller
/// that all tabs share, keeps the installed extensions on disk, saves their permissions
/// (WebKit does not), and answers WebKit's questions about tabs, windows and prompts.
@MainActor
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()

    let controller: WKWebExtensionController = {
        // Extensions find the browser by user agent. WebKit's plain user agent names no
        // browser, so Bitwarden stops at launch. Use the tabs' Safari user agent: a Chrome
        // one makes Bitwarden call Chrome-only APIs that WebKit rejects.
        let configuration = WKWebExtensionController.Configuration.default()
        let webViewConfiguration = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        webViewConfiguration.applicationNameForUserAgent = Defaults.userAgentApplicationName
        configuration.webViewConfiguration = webViewConfiguration
        return WKWebExtensionController(configuration: configuration)
    }()

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
        keepAlive.tolerance = 3
    }

    // MARK: Keeping workers loaded

    /// WebKit unloads a non-persistent worker or background page 30 s after the last event it
    /// sent to it (WebExtensionContext::scheduleBackgroundContentToUnload). An open popup does
    /// not count: Bitwarden's worker went away while its popup waited for a login code, and the
    /// login failed. A worker loaded again is not safe either: WebKit can put it in another
    /// process than the popup, and then they cannot reach each other. `loadBackgroundContent`
    /// starts WebKit's 30 s again, so it is called for each loaded extension well inside that
    /// time, and the workers stay loaded, as persistent background pages do.
    private lazy var keepAlive = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
        MainActor.assumeIsolated { ExtensionManager.shared.keepWorkersLoaded() }
    }

    private func keepWorkersLoaded() {
        for context in contexts.values where context.webExtension.hasBackgroundContent {
            context.loadBackgroundContent { _ in }
        }
        for (id, port) in workerPorts where contexts[id] != nil {
            if workerPings[id] != nil {
                revive(id, because: "its worker stopped answering the app")
                continue
            }
            workerPings[id] = Date()
            port.sendMessage(["ping": Date().timeIntervalSince1970], completionHandler: nil)
        }
    }

    // MARK: Watching workers (the "bosk.alive" port a worker's shim holds)

    private var workerPorts: [String: WKWebExtension.MessagePort] = [:]
    /// When a ping went out that has no answer yet.
    private var workerPings: [String: Date] = [:]

    /// WebKit can end a worker and still count it as loaded; then each message to it goes
    /// nowhere, for good, and a popup only shows its spinner (seen with Bitwarden a few seconds
    /// after its start, cause not known). Bosk pings the worker on this port from
    /// `keepWorkersLoaded`. No answer by the next ping, or the port gone while the extension
    /// stays loaded, and the extension is loaded again.
    func watchWorker(_ port: WKWebExtension.MessagePort, of context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        workerPorts[id] = port
        workerPings[id] = nil
        port.messageHandler = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.workerPorts[id] === port else { return }
                self.workerPings[id] = nil
            }
        }
        port.disconnectHandler = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.workerPorts[id] === port else { return }
                self.workerPorts[id] = nil
                self.workerPings[id] = nil
                // Still this context: the worker went, not the extension.
                guard self.contexts[id] === context else { return }
                self.revive(id, because: "its worker went away")
            }
        }
    }

    /// One of the extension's pages is on screen: its popup, or a tab at one of its addresses.
    func hasVisiblePage(_ id: String) -> Bool {
        guard let context = contexts[id] else { return false }
        return windowsProvider?().contains { window in
            if window.showsPopup(of: context) { return true }
            guard let url = window.store.selectedTab?.url else { return false }
            return url.scheme == context.baseURL.scheme && url.host() == context.baseURL.host()
        } ?? false
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
                // One after another, a moment apart: started all at once, WebKit fails some of
                // their workers and does not try them again (found by Search, see ExtensionShim).
                if contexts[record.id]?.webExtension.hasBackgroundContent == true {
                    try? await Task.sleep(for: .milliseconds(400))
                }
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

    /// Adds the shim this build carries (ExtensionShim), off the main thread: the first launch
    /// after an update reads and rewrites every script and page of each extension.
    /// - Parameter fresh: The folder was just unpacked or copied in.
    private func prepare(_ fileName: String, fresh: Bool) async throws {
        let folder = directory.appending(path: fileName)
        let version = WebStoreBridge.chromeVersion
        #if DEBUG
        // Debug builds log what extensions write to console.error and console.warn.
        let verbose = true
        #else
        let verbose = false
        #endif
        try await Task.detached(priority: .userInitiated) {
            try ExtensionShim.prepare(folder, chromeVersion: version, verbose: verbose, fresh: fresh)
        }.value
    }

    /// The installed extension's folder.
    func folder(for id: String) -> URL {
        directory.appending(path: records.first { $0.id == id }?.fileName ?? id)
    }

    private func load(_ record: Record, fresh: Bool = false) async throws {
        do {
            try await prepare(record.fileName, fresh: fresh)
        } catch {
            NSLog("Bosk: could not add the shim to %@: %@", record.fileName, "\(error)")
        }
        let webExtension = try await WKWebExtension(resourceBaseURL: directory.appending(path: record.fileName))
        let context = WKWebExtensionContext(for: webExtension)
        // A stable ID keeps the extension's storage and its chrome-extension:// origin.
        context.uniqueIdentifier = record.id
        context.grantedPermissions = Self.permissions(record.grantedPermissions)
        context.deniedPermissions = Self.permissions(record.deniedPermissions)
        context.grantedPermissionMatchPatterns = Self.patterns(record.grantedMatchPatterns)
        context.deniedPermissionMatchPatterns = Self.patterns(record.deniedMatchPatterns)
        // The shim reaches Bosk through native messages.
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        #if DEBUG
        context.isInspectable = true
        #endif
        try controller.load(context)
        watchErrors(of: context)
        if contexts[record.id] == nil, loadsThisRun.contains(record.id) { loadedBefore.insert(record.id) }
        loadsThisRun.insert(record.id)
        contexts[record.id] = context
    }

    // MARK: Restarting (ported from Search by Office Commun, MIT License)

    /// Loaded at least once in this run of Bosk, and loaded again. The shim then tells the
    /// extension "update", not "install", so it does not open its welcome page again.
    private var loadsThisRun: Set<String> = []
    private(set) var loadedBefore: Set<String> = []
    private var revived: [String: Date] = [:]
    private var errorObservers: [String: NSObjectProtocol] = [:]
    /// Recent failed native messages, by extension and host (see ExtensionBridge).
    var nativeFailures: [String: [Date]] = [:]

    /// Unloads and loads an extension whose worker does not start again, as a relaunch would.
    /// At most once a minute, so an extension that can never start does not loop.
    func revive(_ id: String, because reason: String) {
        guard contexts[id] != nil, Date().timeIntervalSince(revived[id] ?? .distantPast) > 60 else { return }
        revived[id] = Date()
        saveRegistry() // The record then has the permissions granted since launch.
        guard let record = records.first(where: { $0.id == id }), record.enabled else { return }
        NSLog("Bosk: restarted extension %@: %@", record.fileName, reason)
        unload(id)
        Task {
            try? await load(record)
            changed()
        }
    }

    /// WebKit records a worker that failed to start as an error on its context, and then does
    /// not try again. The extension is loaded again as soon as that shows.
    private func watchErrors(of context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        if let old = errorObservers[id] { NotificationCenter.default.removeObserver(old) }
        errorObservers[id] = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main
        ) { [weak context] _ in
            MainActor.assumeIsolated {
                guard let context, ExtensionManager.shared.contexts[id] === context else { return }
                let failed = context.errors.contains { error in
                    let error = error as NSError
                    return error.domain == WKWebExtensionContext.errorDomain
                        && error.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
                }
                guard failed else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard ExtensionManager.shared.contexts[id] === context else { return }
                    ExtensionManager.shared.revive(id, because: "its worker failed to start")
                }
            }
        }
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
        if record.enabled { try await load(record, fresh: true) }
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
        try await prepare(record.fileName, fresh: true)
        let webExtension = try await WKWebExtension(resourceBaseURL: directory.appending(path: record.fileName))
        // The prompt shows what the extension asked for, not what Bosk added for its shim.
        let added = Set(ExtensionShim.addedPermissions(in: directory.appending(path: record.fileName)))
        let summary = PermissionText.summary(permissions: webExtension.requestedPermissions.filter { !added.contains($0.rawValue) },
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
        workerPorts[id] = nil
        workerPings[id] = nil
        ExtensionShimAnswers.forget(id)
        if let observer = errorObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
        try? controller.unload(context)
        // Its ports show as gone only after WebKit has had a turn.
        DispatchQueue.main.async { ExtensionNative.stopOrphans() }
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
        ExtensionAuth.tabClosed(tab)
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
