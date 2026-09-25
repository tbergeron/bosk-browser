import AppKit
import AVFoundation
import BoskCore
import CryptoKit
import IOKit.pwr_mgt
import NaturalLanguage
import UserNotifications
import WebKit

/// Answers the native messages that `bosk-shim.js` sends to "bosk": the Chrome APIs WebKit
/// does not have, from Bosk's own bookmarks, history, downloads and tabs. Ported from Search by
/// Office Commun (MIT License, https://github.com/driceroland/Search, ExtensionShims.swift),
/// changed for Bosk: bookmarks are one flat list, and there are several windows.
@MainActor
enum ExtensionShimAnswers {
    struct Unsupported: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    /// Offscreen documents, one per extension, as Chrome allows.
    private static var offscreen: [String: WKWebView] = [:]
    /// The side panel page each extension set, and if its button opens it.
    private static var panelPath: [String: String] = [:]
    private static var panelOnClick: Set<String> = []
    /// One voice for every extension that reads aloud.
    private static let speaker = AVSpeechSynthesizer()
    /// Keep-awake assertions, one per extension that asked.
    private static var awake: [String: IOPMAssertionID] = [:]

    static func answer(_ message: Any, from context: WKWebExtensionContext) async -> Any {
        guard let body = message as? [String: Any], let api = body["api"] as? String else {
            return ["error": "Not a Bosk message"]
        }
        do {
            return ["value": try await run(api, body["args"] as? [Any] ?? [], context: context) ?? NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// The API families whose answers are about the person (their bookmarks, history…).
    /// WebKit keeps no permission for them, so the gate reads the extension's own manifest.
    private static let gates: [String: String] = [
        "bookmarks": "bookmarks", "history": "history", "downloads": "downloads", "sessions": "sessions",
        "topSites": "topSites", "browsingData": "browsingData", "readingList": "readingList",
        "userScripts": "userScripts", "identity": "identity",
    ]

    private static func grantedKey(_ id: String) -> String { "extensions.granted.\(id)" }
    private static func settingsKey(_ id: String) -> String { "extensions.settings.\(id)" }

    /// What the extension asked for: its manifest, and optional ones granted since. The checks in
    /// the shim run beside the extension's own code, so the check that counts is here.
    private static func allowed(_ id: String, context: WKWebExtensionContext) -> Set<String> {
        let asked = (context.webExtension.manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        return Set(asked + (UserDefaults.standard.stringArray(forKey: grantedKey(id)) ?? []))
    }

    /// The window extensions see as current. Tab indexes are in this window.
    private static var window: BrowserWindowController? { ExtensionManager.shared.focusedWindowController }
    private static var tabs: [Tab] { window?.store.allTabs ?? [] }

    private static func run(_ api: String, _ args: [Any], context: WKWebExtensionContext) async throws -> Any? {
        let first = args.first
        let id = context.uniqueIdentifier
        let manager = ExtensionManager.shared

        if api.hasPrefix("setting.") {
            // A browser setting (chrome.privacy…) belongs to the family its name starts with.
            let name = api.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let family = String(name.prefix { $0 != "." })
            guard !family.isEmpty, allowed(id, context: context).contains(family) else {
                throw Unsupported(what: "The extension never asked for “\(family)”")
            }
            return setting(api, first as? [String: Any] ?? [:], extension: id)
        }
        if api == "tabs.describe", !context.hasPermission(.tabs) {
            throw Unsupported(what: "The extension never asked for “tabs”")
        }
        if let needed = gates[String(api.prefix { $0 != "." })], !allowed(id, context: context).contains(needed) {
            throw Unsupported(what: "The extension never asked for “\(needed)”")
        }

        switch api {
        // MARK: bookmarks: one flat list, shown as the bookmarks bar ("1")
        case "bookmarks.getTree":
            return [root()]
        case "bookmarks.getSubTree":
            let key = first as? String ?? ""
            if key == "0" { return [root()] }
            if key == "1" { return [bar(deep: true)] }
            return bookmark(key).map { [$0] } ?? []
        case "bookmarks.getChildren":
            let key = first as? String ?? "1"
            if key == "0" { return [bar(deep: false)] }
            return key == "1" ? bookmarkNodes() : []
        case "bookmarks.get":
            let keys = (first as? [String]) ?? (first as? String).map { [$0] } ?? []
            return keys.compactMap(bookmark)
        case "bookmarks.getRecent":
            return Array(bookmarkNodes().suffix((first as? Int) ?? 10).reversed())
        case "bookmarks.search":
            let spec = first as? [String: Any]
            let query = (first as? String) ?? (spec?["query"] as? String) ?? ""
            let words = query.lowercased().split(separator: " ").map(String.init)
            return bookmarkNodes().filter { node in
                if let url = spec?["url"] as? String, node["url"] as? String != url { return false }
                if let title = spec?["title"] as? String, node["title"] as? String != title { return false }
                let hay = "\(node["title"] ?? "") \(node["url"] ?? "")".lowercased()
                return words.allSatisfy(hay.contains)
            }
        case "bookmarks.create":
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else {
                throw Unsupported(what: "Bosk has no bookmark folders")
            }
            BookmarkStore.shared.add(url: url, title: spec["title"] as? String ?? "")
            return BookmarkStore.shared.bookmark(for: url).flatMap { bookmark($0.id.uuidString) }
        case "bookmarks.update":
            guard let key = first as? String, let uuid = UUID(uuidString: key) else { throw Unsupported(what: "No such bookmark") }
            let changes = args.dropFirst().first as? [String: Any] ?? [:]
            BookmarkStore.shared.update(id: uuid, title: changes["title"] as? String,
                                        url: (changes["url"] as? String).flatMap(URL.init(string:)))
            return bookmark(key)
        case "bookmarks.move":
            // One list, one parent: nothing to move to.
            return bookmark(first as? String ?? "")
        case "bookmarks.remove", "bookmarks.removeTree":
            guard let key = first as? String, let uuid = UUID(uuidString: key) else { throw Unsupported(what: "No such bookmark") }
            BookmarkStore.shared.remove(id: uuid)
            return nil

        // MARK: history
        case "history.search":
            let spec = first as? [String: Any] ?? [:]
            let start = (spec["startTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? Date().addingTimeInterval(-24 * 3600)
            let end = (spec["endTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantFuture
            return await HistoryStore.shared.visits(for: spec["text"] as? String ?? "")
                .filter { $0.lastVisit >= start && $0.lastVisit <= end }
                .prefix(spec["maxResults"] as? Int ?? 100)
                .map(visit)
        case "history.getVisits":
            let url = (first as? [String: Any])?["url"] as? String ?? ""
            return await HistoryStore.shared.visits(for: url).filter { $0.url.absoluteString == url }.map { item in
                ["id": item.url.absoluteString, "visitId": "1", "visitTime": item.lastVisit.timeIntervalSince1970 * 1000,
                 "referringVisitId": "0", "transition": "link"] as [String: Any]
            }
        case "history.addUrl":
            if let url = ((first as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) {
                await HistoryStore.shared.recordVisit(url: url, title: "")
            }
            return nil
        case "history.deleteUrl":
            if let url = ((first as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) {
                await HistoryStore.shared.remove(url: url)
            }
            return nil
        case "history.deleteRange":
            let spec = first as? [String: Any] ?? [:]
            await HistoryStore.shared.remove(from: Date(timeIntervalSince1970: (spec["startTime"] as? Double ?? 0) / 1000),
                                       to: Date(timeIntervalSince1970: (spec["endTime"] as? Double ?? 0) / 1000))
            return nil
        case "history.deleteAll":
            await HistoryStore.shared.clear()
            return nil

        // MARK: downloads
        case "downloads.download":
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No url to download") }
            guard let webView = window?.store.selectedTab?.webView ?? tabs.lazy.compactMap(\.webView).first else {
                throw Unsupported(what: "No page to download through")
            }
            let download = await webView.startDownload(using: URLRequest(url: url))
            DownloadManager.shared.track(download)
            return DownloadManager.shared.items.count
        case "downloads.search":
            return DownloadManager.shared.items.enumerated().map { index, item -> [String: Any] in
                let url = item.download.originalRequest?.url?.absoluteString ?? ""
                let state = item.state == .finished ? "complete" : item.state == .failed ? "interrupted" : "in_progress"
                return ["id": index + 1, "url": url, "finalUrl": url, "filename": item.destination?.path ?? "",
                        "state": state, "exists": item.destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                        "mime": ""]
            }
        case "downloads.open", "downloads.show":
            let items = DownloadManager.shared.items
            guard let index = first as? Int, items.indices.contains(index - 1),
                  let destination = items[index - 1].destination else { return nil }
            if api == "downloads.open" {
                NSWorkspace.shared.open(destination)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
            return nil
        case "downloads.showDefaultFolder":
            if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                NSWorkspace.shared.open(folder)
            }
            return nil
        case "downloads.erase":
            return []
        case "downloads.pause", "downloads.resume", "downloads.cancel", "downloads.removeFile", "downloads.getFileIcon":
            throw Unsupported(what: "\(api) isn't available in Bosk")

        // MARK: side panel: a tab of its own
        case "sidePanel.setOptions":
            if let path = (first as? [String: Any])?["path"] as? String { panelPath[id] = path }
            return nil
        case "sidePanel.getOptions":
            return ["enabled": true, "path": panelPath[id] ?? defaultPanel(context) ?? ""]
        case "sidePanel.setPanelBehavior":
            if let on = (first as? [String: Any])?["openPanelOnActionClick"] as? Bool {
                if on { panelOnClick.insert(id) } else { panelOnClick.remove(id) }
            }
            return nil
        case "sidePanel.getPanelBehavior":
            return ["openPanelOnActionClick": panelOnClick.contains(id)]
        case "sidePanel.open":
            if let path = panelPath[id] ?? defaultPanel(context) {
                window?.store.newTab(url: context.baseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
            }
            return nil

        // MARK: offscreen: a page with a DOM, for a worker that has none
        case "offscreen.createDocument":
            guard offscreen[id] == nil else { throw Unsupported(what: "Only a single offscreen document may be created.") }
            guard let path = (first as? [String: Any])?["url"] as? String, let configuration = context.webViewConfiguration else {
                throw Unsupported(what: "No page for the offscreen document")
            }
            let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            page.load(URLRequest(url: context.baseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))))
            offscreen[id] = page
            // Answered when the page has loaded, as Chrome does: the worker's next line is
            // usually a message to it.
            for _ in 0..<250 where page.isLoading || page.url == nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        case "offscreen.closeDocument":
            offscreen[id] = nil
            return nil
        case "offscreen.hasDocument":
            return offscreen[id] != nil

        // MARK: fonts: what the Mac has
        case "fontSettings.getFontList":
            return NSFontManager.shared.availableFontFamilies.map { ["fontId": $0, "displayName": $0] }
        case "fontSettings.getFont":
            return ["fontId": "", "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFontSize":
            return ["pixelSize": 16, "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFixedFontSize":
            return ["pixelSize": 13, "levelOfControl": "not_controllable"]
        case "fontSettings.getMinimumFontSize":
            return ["pixelSize": 0, "levelOfControl": "not_controllable"]
        case _ where api.hasPrefix("fontSettings.set") || api.hasPrefix("fontSettings.clear"):
            return nil

        // MARK: management: only itself
        case "management.getSelf", "management.get":
            let found = context.webExtension
            let unpacked = manager.records.first { $0.id == id }?.sourcePath != nil
            return ["id": id, "name": found.displayName ?? "", "shortName": found.displayShortName ?? "",
                    "version": found.version ?? "", "description": found.displayDescription ?? "",
                    "enabled": true, "type": "extension", "installType": unpacked ? "development" : "normal",
                    "mayDisable": true, "offlineEnabled": true, "isApp": false, "hostPermissions": [], "permissions": []]
        case "management.getAll":
            return []
        case "management.setEnabled", "management.uninstallSelf":
            throw Unsupported(what: "Extensions are turned on and off in Settings > Extensions")

        // MARK: language
        case "i18n.detectLanguage":
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(first as? String ?? "")
            let guesses = recognizer.languageHypotheses(withMaximum: 3)
            return ["isReliable": (guesses.values.max() ?? 0) > 0.6,
                    "languages": guesses.sorted { $0.value > $1.value }
                        .map { ["language": $0.key.rawValue, "percentage": Int($0.value * 100)] }]
        case "runtime.getContexts":
            // The pages Chrome would list: the worker, the popup while it shows, the offscreen
            // document. Bitwarden asks for these to know where to send its messages.
            let filter = first as? [String: Any] ?? [:]
            let types = filter["contextTypes"] as? [String]
            let urls = filter["documentUrls"] as? [String]
            var found: [[String: Any]] = []
            func add(_ type: String, _ url: URL?) {
                guard types?.contains(type) ?? true else { return }
                let address = url?.absoluteString ?? ""
                guard urls?.contains(address) ?? true else { return }
                found.append(["contextType": type, "contextId": "\(id)-\(type)", "tabId": -1, "windowId": -1,
                              "frameId": type == "BACKGROUND" ? -1 : 0, "documentUrl": address,
                              "documentOrigin": url.map { "\($0.scheme ?? "")://\($0.host() ?? "")" } ?? "",
                              "incognito": false])
            }
            if context.webExtension.hasBackgroundContent {
                let background = context.webExtension.manifest["background"] as? [String: Any] ?? [:]
                let script = background["service_worker"] as? String ?? background["page"] as? String
                add("BACKGROUND", script.map { context.baseURL.appending(path: $0) })
            }
            if let action = context.action(for: nil), action.popupPopover?.isShown == true {
                add("POPUP", action.popupWebView?.url)
            }
            if let page = offscreen[id] { add("OFFSCREEN_DOCUMENT", page.url) }
            return found

        // MARK: notifications: the Mac's own
        case "notifications.create":
            let named = first as? String
            let options = (named == nil ? first : args.dropFirst().first) as? [String: Any] ?? [:]
            let key = named ?? UUID().uuidString
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = options["title"] as? String ?? (context.webExtension.displayName ?? "")
            content.body = options["message"] as? String ?? ""
            content.subtitle = context.webExtension.displayName ?? ""
            try? await center.add(UNNotificationRequest(identifier: "\(id).\(key)", content: content, trigger: nil))
            return key
        case "notifications.clear":
            if let key = first as? String {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["\(id).\(key)"])
            }
            return true
        case "notifications.getAll":
            return [String: Any]()
        case "notifications.getPermissionLevel":
            return "granted"
        case "notifications.update":
            return false

        // MARK: speech
        case "tts.speak":
            let options = args.dropFirst().first as? [String: Any] ?? [:]
            if !(options["enqueue"] as? Bool ?? false) { speaker.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: first as? String ?? "")
            if let name = options["voiceName"] as? String {
                utterance.voice = AVSpeechSynthesisVoice.speechVoices().first { $0.name == name }
            } else if let lang = options["lang"] as? String {
                utterance.voice = AVSpeechSynthesisVoice(language: lang)
            }
            // Chrome's rate 1 is normal speed, from 0.1 to 10.
            if let rate = options["rate"] as? Double {
                utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                                     max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate)))
            }
            speaker.speak(utterance)
            return nil
        case "tts.stop":
            speaker.stopSpeaking(at: .immediate)
            return nil
        case "tts.pause":
            speaker.pauseSpeaking(at: .immediate)
            return nil
        case "tts.resume":
            speaker.continueSpeaking()
            return nil
        case "tts.isSpeaking":
            return speaker.isSpeaking
        case "tts.getVoices":
            return AVSpeechSynthesisVoice.speechVoices().map { voice -> [String: Any] in
                ["voiceName": voice.name, "lang": voice.language, "remote": false, "eventTypes": ["start", "end"]]
            }

        // MARK: the worker, up before a page talks to it
        case "background.wake":
            guard context.webExtension.hasBackgroundContent else { return nil }
            // WebKit sometimes fails to start a worker again after it unloads it, and then does
            // not try again: every message waits forever. Tried twice more, then the extension
            // is loaded again.
            for attempt in 0..<3 {
                // WebKit never calls back after some failed starts: 8 s without an answer is a failure.
                let error: Error? = await withCheckedContinuation { done in
                    var finished = false
                    let finish: (Error?) -> Void = { result in
                        guard !finished else { return }
                        finished = true
                        done.resume(returning: result)
                    }
                    context.loadBackgroundContent { error in MainActor.assumeIsolated { finish(error) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(Unsupported(what: "no answer from WebKit")) }
                }
                guard error != nil else { return nil }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
            }
            manager.revive(id, because: "its worker did not start")
            return nil
        // If this extension was loaded before in this run of Bosk: an "install" then is a restart.
        case "background.loadedBefore":
            return manager.loadedBefore.contains(id)
        // A page found the worker gone, though WebKit believes it runs.
        case "background.revive":
            manager.revive(id, because: "its worker stopped answering")
            return nil

        case "debug.error":
            NSLog("Bosk: extension %@: %@", id, first as? String ?? "?")
            return nil

        // Bosk shows WebKit's own popup, so it does not need to know the popup page.
        case "action.popup":
            return nil

        // MARK: user scripts
        case "userScripts.file":
            return try userScriptFile(first as? [String: Any] ?? [:], in: manager.folder(for: id))
        case "userScripts.list":
            let url = manager.folder(for: id).appending(path: "\(ExtensionShim.dataFolder)/userscripts.json")
            return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) ?? []
        case "userScripts.save":
            let folder = manager.folder(for: id).appending(path: ExtensionShim.dataFolder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let scripts = first as? [[String: Any]] ?? []
            try JSONSerialization.data(withJSONObject: scripts).write(to: folder.appending(path: "userscripts.json"), options: .atomic)
            // Files that no saved script uses any more, after a minute: one that is being
            // injected now stays.
            let keep = Set(scripts.compactMap { try? userScriptFile($0, in: manager.folder(for: id)) }
                .map { URL(fileURLWithPath: $0).lastPathComponent })
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.lastPathComponent.hasPrefix("us-") && !keep.contains(file.lastPathComponent) {
                let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    .map { -$0.timeIntervalSinceNow } ?? 999
                if age > 60 { try? FileManager.default.removeItem(at: file) }
            }
            return nil
        case "userScripts.world", "userScripts.worlds":
            let url = manager.folder(for: id).appending(path: "\(ExtensionShim.dataFolder)/worlds.json")
            var worlds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            if api == "userScripts.worlds" { return worlds }
            let props = first as? [String: Any] ?? [:]
            let world = props["worldId"] as? String ?? ""
            worlds.removeAll { ($0["worldId"] as? String ?? "") == world }
            if props["reset"] as? Bool != true { worlds.append(props) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: worlds).write(to: url, options: .atomic)
            return nil

        // MARK: permissions Bosk grants itself (the APIs above)
        case "permissions.granted":
            return UserDefaults.standard.stringArray(forKey: grantedKey(id)) ?? []
        case "permissions.request":
            let wanted = (first as? [String]) ?? []
            // As in Chrome: only what the manifest named, as a permission or an optional one.
            let manifest = context.webExtension.manifest
            let named = Set(((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? []))
                .compactMap { $0 as? String })
            guard wanted.allSatisfy(named.contains) else {
                throw Unsupported(what: "Only permissions specified in the manifest may be requested.")
            }
            // Chrome grants these without a question: there is nothing to warn about.
            let silent: Set<String> = ["tabGroups", "sidePanel", "offscreen", "idle", "power", "fontSettings", "search",
                                       "system.cpu", "system.memory", "system.display", "favicon"]
            if !wanted.allSatisfy(silent.contains) {
                let name = context.webExtension.displayName ?? "An extension"
                let names = wanted.map { $0.replacingOccurrences(of: ".", with: " ") }.joined(separator: ", ")
                guard await ExtensionPrompts.confirm(title: "“\(name)” asks for more access", message: "It can use: \(names)",
                                                     confirmTitle: "Allow", in: window?.window) else { return false }
            }
            let had = UserDefaults.standard.stringArray(forKey: grantedKey(id)) ?? []
            UserDefaults.standard.set(Array(Set(had + wanted)).sorted(), forKey: grantedKey(id))
            return true
        case "permissions.remove":
            let gone = Set((first as? [String]) ?? [])
            let had = UserDefaults.standard.stringArray(forKey: grantedKey(id)) ?? []
            UserDefaults.standard.set(had.filter { !gone.contains($0) }, forKey: grantedKey(id))
            return true

        // MARK: tabs, by their index in the current window
        case "tabs.describe":
            let all = tabs
            return ((first as? [Int]) ?? []).map { index -> Any in
                guard all.indices.contains(index) else { return NSNull() }
                return ["url": all[index].url?.absoluteString ?? "", "title": all[index].title]
            }
        case "tabs.move", "tabs.discard", "tabs.activate":
            let all = tabs
            guard let from = first as? Int, all.indices.contains(from), let store = window?.store else {
                throw Unsupported(what: "No tab there")
            }
            let tab = all[from]
            switch api {
            case "tabs.move":
                guard !tab.isPinned else { throw Unsupported(what: "Pinned tabs keep their place") }
                let wanted = args.dropFirst().first as? Int ?? -1
                let index = wanted < 0 ? store.tabs.count - 1 : min(max(0, wanted - store.pinnedTabs.count), store.tabs.count - 1)
                store.moveTab(tab, to: index, group: tab.groupID)
            case "tabs.discard":
                if tab !== store.selectedTab { tab.sleep() }
            default:
                store.select(tab)
            }
            return nil

        // MARK: search
        case "search.query":
            let spec = first as? [String: Any] ?? [:]
            guard let url = InputClassifier.url(for: spec["text"] as? String ?? "", searchURL: Defaults.searchURL) else { return nil }
            switch spec["disposition"] as? String {
            case "NEW_TAB", "NEW_WINDOW": window?.store.newTab(url: url)
            default: window?.store.selectedTab?.load(url)
            }
            return nil

        // MARK: idle
        case "idle.queryState":
            let threshold = (first as? Double) ?? 60
            if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
               session["CGSSessionScreenIsLocked"] as? Bool == true { return "locked" }
            let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            return quiet >= threshold ? "idle" : "active"
        case "idle.getAutoLockDelay":
            return 0

        // MARK: power
        case "power.requestKeepAwake":
            if let old = awake[id] { IOPMAssertionRelease(old) }
            var assertion: IOPMAssertionID = 0
            let kind = ((first as? String) == "display" ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                                                        : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
            if IOPMAssertionCreateWithName(kind, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "An extension in Bosk" as CFString, &assertion) == kIOReturnSuccess {
                awake[id] = assertion
            }
            return nil
        case "power.releaseKeepAwake":
            if let old = awake.removeValue(forKey: id) { IOPMAssertionRelease(old) }
            return nil
        case "power.reportActivity":
            var assertion: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("An extension in Bosk" as CFString, kIOPMUserActiveLocal, &assertion)
            return nil

        // MARK: browsing data
        case "browsingData.settings":
            return ["options": ["since": 0], "dataToRemove": [:], "dataRemovalPermitted": [
                "cache": true, "cookies": true, "history": true, "downloads": true, "localStorage": true,
                "indexedDB": true, "serviceWorkers": true, "cacheStorage": true, "fileSystems": true, "webSQL": true,
            ]]
        case _ where api.hasPrefix("browsingData."):
            let options = first as? [String: Any] ?? [:]
            let what: [String: Bool]
            if api == "browsingData.remove" {
                what = (args.dropFirst().first as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
            } else {
                let key = String(api.dropFirst("browsingData.remove".count))
                what = [key.prefix(1).lowercased() + key.dropFirst(): true]
            }
            await clear(what, options: options)
            return nil

        // MARK: sessions: the tabs closed in the current window
        case "sessions.getRecentlyClosed":
            let limit = (first as? [String: Any])?["maxResults"] as? Int ?? 25
            let closed = window?.store.closedTabs ?? []
            return closed.enumerated().reversed().prefix(limit).map { index, tab -> [String: Any] in
                ["lastModified": Int(Date().timeIntervalSince1970),
                 "tab": ["sessionId": String(index), "url": tab.url?.absoluteString ?? "", "title": tab.title,
                         "index": tab.index, "windowId": 1, "active": false, "pinned": false, "highlighted": false,
                         "incognito": false, "selected": false, "discarded": false, "autoDiscardable": true, "groupId": -1]]
            }
        case "sessions.getDevices":
            return []
        case "sessions.restore":
            // Bosk reopens the last closed tab only.
            guard let store = window?.store, let last = store.closedTabs.last,
                  first == nil || (first as? String) == String(store.closedTabs.count - 1)
            else { throw Unsupported(what: "Bosk can restore only the last closed tab") }
            store.reopenClosedTab()
            return ["lastModified": Int(Date().timeIntervalSince1970),
                    "tab": ["url": last.url?.absoluteString ?? "", "title": last.title, "index": last.index, "windowId": 1]]

        // MARK: top sites: the most visited in history
        case "topSites.get":
            var visits: [String: (url: URL, title: String, count: Int)] = [:]
            for item in await HistoryStore.shared.visits(for: "") {
                guard let host = item.url.host() else { continue }
                visits[host, default: (item.url, item.title, 0)].count += item.visitCount
            }
            return visits.values.sorted { $0.count > $1.count }.prefix(10).map { ["url": $0.url.absoluteString, "title": $0.title] }

        // MARK: reading list: none kept
        case "readingList.query":
            return []
        case "readingList.addEntry", "readingList.removeEntry", "readingList.updateEntry":
            throw Unsupported(what: "Bosk has no reading list")

        // MARK: system
        case "system.cpu.getInfo":
            return ["numOfProcessors": ProcessInfo.processInfo.processorCount, "archName": "arm64",
                    "modelName": "Apple silicon", "features": [], "processors": [], "temperatures": []]
        case "system.memory.getInfo":
            let memory = Double(ProcessInfo.processInfo.physicalMemory)
            return ["capacity": memory, "availableCapacity": memory / 2]
        case "system.storage.getInfo":
            return []
        case "system.display.getInfo":
            return NSScreen.screens.enumerated().map { index, screen -> [String: Any] in
                let frame = screen.frame, visible = screen.visibleFrame
                return ["id": String(index), "name": screen.localizedName, "isPrimary": index == 0, "isInternal": index == 0,
                        "isEnabled": true, "dpiX": 96 * screen.backingScaleFactor, "dpiY": 96 * screen.backingScaleFactor,
                        "rotation": 0,
                        "bounds": ["left": frame.minX, "top": frame.minY, "width": frame.width, "height": frame.height],
                        "workArea": ["left": visible.minX, "top": visible.minY, "width": visible.width, "height": visible.height]]
            }

        // MARK: tab groups: not shown to extensions
        case "tabGroups.query":
            return []
        case "tabGroups.get", "tabGroups.update", "tabGroups.move":
            throw Unsupported(what: "Bosk does not show its tab groups to extensions")

        // MARK: identity
        case "identity.launchWebAuthFlow":
            guard let url = ((first as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)), let store = window?.store else {
                throw Unsupported(what: "No authorization url")
            }
            return try await ExtensionAuth.run(url, extension: id, in: store).absoluteString
        case "identity.getProfileUserInfo":
            return ["email": "", "id": ""]
        case "identity.removeCachedAuthToken", "identity.clearAllCachedAuthTokens":
            return nil
        case "identity.getAuthToken":
            throw Unsupported(what: "getAuthToken needs a Google account signed in to Chrome; use launchWebAuthFlow")

        default:
            throw Unsupported(what: "\(api) isn't available in Bosk")
        }
    }

    // MARK: Helpers

    /// A user script as a file WebKit can inject: its code, inside a block that stops at once on
    /// a page its globs exclude and, for Chrome's USER_SCRIPT world, gives the code a `chrome`
    /// whose messages are marked as a user script's. Named by its content, so a changed script
    /// is a new file and never one WebKit has already read.
    private static func userScriptFile(_ script: [String: Any], in folder: URL) throws -> String {
        let json = { (value: Any) in
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        var code = ""
        for source in script["js"] as? [[String: Any]] ?? [] {
            if let inline = source["code"] as? String {
                code += inline + "\n;\n"
            } else if let file = source["file"] as? String, let path = ExtensionShim.inside(file, of: folder),
                      let text = try? String(contentsOf: path, encoding: .utf8) {
                code += text + "\n;\n"
            }
        }
        let userWorld = (script["world"] as? String) != "MAIN"
        let prelude = #"""
          const chrome = (() => {
            const runtime = globalThis.chrome.runtime;
            return { runtime: {
              id: runtime.id, getURL: (path) => runtime.getURL(path), get lastError() { return runtime.lastError; },
              sendMessage: (message, ...rest) => runtime.sendMessage({ __boskUserScript: true, message }, ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))),
              connect: (info) => runtime.connect({ ...(info || {}), name: "bosk-us:" + ((info && info.name) || "") }),
            } };
          })();
          const browser = chrome;
        """#
        let text = #"""
        /* Bosk: a user script (chrome.userScripts) */
        bosk_user_script: {
          const __boskHref = location.href;
          const __boskGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
          const __boskIn = \#(json(script["includeGlobs"] ?? [])), __boskOut = \#(json(script["excludeGlobs"] ?? []));
          if ((__boskIn.length && !__boskIn.some((g) => __boskGlob(g).test(__boskHref))) || __boskOut.some((g) => __boskGlob(g).test(__boskHref))) break bosk_user_script;
        \#(userWorld ? prelude : "")
        \#(code)
        }
        """#
        let digest = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = "us-\(digest).js"
        let directory = folder.appending(path: ExtensionShim.dataFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        return "\(ExtensionShim.dataFolder)/\(name)"
    }

    /// chrome.privacy and chrome.proxy: what each extension set, kept across launches as Chrome
    /// keeps it. Bosk does not act on these values.
    private static func setting(_ api: String, _ details: [String: Any], extension id: String) -> Any? {
        let parts = api.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[1]
        var mine = UserDefaults.standard.dictionary(forKey: settingsKey(id)) ?? [:]
        switch parts[0] {
        case "setting.set":
            mine[name] = details["value"]
        case "setting.clear":
            mine[name] = nil
        default:
            let value = mine[name] ?? defaultSetting(name)
            return ["value": value ?? NSNull(),
                    "levelOfControl": mine[name] != nil ? "controlled_by_this_extension" : "controllable_by_this_extension"]
        }
        UserDefaults.standard.set(mine, forKey: settingsKey(id))
        return nil
    }

    private static func defaultSetting(_ name: String) -> Any? {
        switch name {
        case "privacy.network.webRTCIPHandlingPolicy": return "default"
        case "privacy.websites.doNotTrackEnabled", "privacy.websites.adMeasurementEnabled",
             "privacy.websites.fledgeEnabled", "privacy.websites.topicsEnabled",
             "privacy.services.safeBrowsingExtendedReportingEnabled": return false
        case "proxy.settings": return ["mode": "system"]
        default: return true
        }
    }

    /// chrome.browsingData, from what WebKit and Bosk keep.
    private static func clear(_ what: [String: Bool], options: [String: Any]) async {
        let since = Date(timeIntervalSince1970: (options["since"] as? Double ?? 0) / 1000)
        let origins = (options["origins"] as? [String])?.compactMap { URL(string: $0)?.host() }
        let map: [String: [String]] = [
            "cache": [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
            "cacheStorage": [WKWebsiteDataTypeFetchCache], "appcache": [WKWebsiteDataTypeOfflineWebApplicationCache],
            "cookies": [WKWebsiteDataTypeCookies], "localStorage": [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage],
            "indexedDB": [WKWebsiteDataTypeIndexedDBDatabases], "serviceWorkers": [WKWebsiteDataTypeServiceWorkerRegistrations],
            "webSQL": [WKWebsiteDataTypeWebSQLDatabases], "fileSystems": [WKWebsiteDataTypeFileSystem],
        ]
        var types = Set<String>()
        for (key, on) in what where on { types.formUnion(map[key] ?? []) }
        let store = WKWebsiteDataStore.default()
        if !types.isEmpty {
            if let origins {
                let records = await store.dataRecords(ofTypes: types)
                let hit = records.filter { record in origins.contains { $0 == record.displayName || $0.hasSuffix("." + record.displayName) } }
                await store.removeData(ofTypes: types, for: hit)
            } else {
                await store.removeData(ofTypes: types, modifiedSince: since)
            }
        }
        if what["history"] == true, origins == nil {
            await HistoryStore.shared.remove(from: since, to: .distantFuture)
        }
    }

    private static func defaultPanel(_ context: WKWebExtensionContext) -> String? {
        (context.webExtension.manifest["side_panel"] as? [String: Any])?["default_path"] as? String
    }

    // MARK: Bookmarks, as Chrome shapes them

    private static func bookmarkNodes() -> [[String: Any]] {
        BookmarkStore.shared.entries.enumerated().map { index, bookmark in
            ["id": bookmark.id.uuidString, "parentId": "1", "index": index, "title": bookmark.title,
             "url": bookmark.url.absoluteString, "dateAdded": 0, "syncing": false]
        }
    }

    private static func bookmark(_ key: String) -> [String: Any]? {
        bookmarkNodes().first { $0["id"] as? String == key }
    }

    private static func bar(deep: Bool) -> [String: Any] {
        var out: [String: Any] = ["id": "1", "parentId": "0", "index": 0, "title": "Bookmarks", "dateAdded": 0,
                                  "folderType": "bookmarks-bar", "syncing": false]
        if deep { out["children"] = bookmarkNodes() }
        return out
    }

    private static func root() -> [String: Any] {
        ["id": "0", "title": "", "dateAdded": 0, "syncing": false, "children": [bar(deep: true)]]
    }

    private static func visit(_ item: SuggestionRanker.HistoryItem) -> [String: Any] {
        ["id": item.url.absoluteString, "url": item.url.absoluteString, "title": item.title,
         "lastVisitTime": item.lastVisit.timeIntervalSince1970 * 1000, "visitCount": item.visitCount, "typedCount": 0]
    }
}

/// chrome.identity.launchWebAuthFlow: a tab for the provider's sign-in. When it tries to go to
/// https://<id>.chromiumapp.org/, that address is the answer and the tab closes. Nothing is ever
/// loaded from chromiumapp.org.
@MainActor
enum ExtensionAuth {
    private static var waiting: [String: (tab: Tab, finish: (Result<URL, Error>) -> Void)] = [:]

    struct Declined: LocalizedError {
        var errorDescription: String? { "The user did not approve access." }
    }

    static func run(_ url: URL, extension id: String, in store: TabStore) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            waiting[id.lowercased()]?.finish(.failure(Declined()))
            let tab = store.newTab(url: url)
            waiting[id.lowercased()] = (tab, { continuation.resume(with: $0) })
        }
    }

    /// Closing the tab is saying no.
    static func tabClosed(_ tab: Tab) {
        for (key, entry) in waiting where entry.tab === tab {
            waiting[key] = nil
            entry.finish(.failure(Declined()))
        }
    }

    /// True when the address is an extension's OAuth redirect in the tab that began the sign-in
    /// (or a window its page opened). Any page can go to an address like this, so only that
    /// tab may finish the flow.
    static func intercept(_ url: URL, in tab: Tab) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(),
              host.hasSuffix(".chromiumapp.org") else { return false }
        let id = String(host.dropLast(".chromiumapp.org".count))
        guard let entry = waiting[id], tab === entry.tab || tab.opener === entry.tab else { return false }
        waiting.removeValue(forKey: id)
        entry.finish(.success(url))
        if tab !== entry.tab { tab.store?.close(tab) }
        entry.tab.store?.close(entry.tab)
        return true
    }
}
