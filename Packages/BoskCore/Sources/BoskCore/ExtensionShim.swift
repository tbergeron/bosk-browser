import CryptoKit
import Foundation

/// The Chrome APIs and Chrome behavior that WebKit does not have, added to each extension.
///
/// Ported from Search by Office Commun (MIT License, https://github.com/driceroland/Search,
/// ExtensionShims.swift). At install and at load, Bosk writes `bosk-shim.js` into the extension's
/// folder and puts it first in the background, in each content script and in each HTML page.
/// The script defines what is missing (bookmarks, offscreen, notifications and more) and sends
/// each call as a native message to the app ("bosk"), which answers. It also works around WebKit
/// bugs: a WebSocket in a service worker deadlocks its process, and a worker that WebKit fails
/// to start again leaves every message without an answer. Files are only added to, never
/// removed from.
public enum ExtensionShim {
    /// The name of native messages to Bosk itself.
    public static let application = "bosk"
    /// The native port a worker's WebSocket goes through (ExtensionSocket.swift).
    public static let socketApplication = "bosk.socket"
    /// The native port a worker holds so Bosk can see that it is still there (ExtensionManager).
    public static let aliveApplication = "bosk.alive"
    public static let file = "bosk-shim.js"
    /// The first line of a worker that already carries the shim.
    static let marker = "/* Bosk: Chrome APIs WebKit lacks, filled in (ExtensionShim.swift) */"
    static let ender = "/* Bosk: end of shim */"
    /// Written beside a prepared extension: which shim it carries. The same one needs nothing
    /// done again, which matters at launch: preparing reads every script and page.
    static let stamp = ".bosk-shim"
    /// The permissions Bosk added to the manifest, so the install prompt shows only what the
    /// extension asked for.
    static let addedFile = ".bosk-added"
    /// User scripts and their worlds (chrome.userScripts), written by the app.
    public static let dataFolder = "_bosk"

    static let version: String = {
        SHA256.hash(data: Data(script.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }()

    public enum Error: Swift.Error, Equatable {
        case noManifest
    }

    /// Adds the shim to the extension in `folder`.
    /// - Parameters:
    ///   - chromeVersion: The version extensions see in the Chrome user agent the shim gives them.
    ///   - verbose: The shim also sends the extension's console errors and warnings to Bosk's log.
    ///   - fresh: A package just unpacked or copied in. Files by Bosk's names that came inside
    ///     it are removed before they are read: only Bosk says what Bosk added.
    public static func prepare(_ folder: URL, chromeVersion: String, verbose: Bool = false, fresh: Bool = false) throws {
        let files = FileManager.default
        if fresh {
            for name in [stamp, addedFile] { try? files.removeItem(at: folder.appending(path: name)) }
        }
        let stampURL = folder.appending(path: stamp)
        let wanted = version + "-" + chromeVersion + (verbose ? "-verbose" : "")
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == wanted { return }
        let manifestURL = folder.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Error.noManifest }

        try shim(for: folder, chromeVersion: chromeVersion, verbose: verbose)
            .write(to: folder.appending(path: file), atomically: true, encoding: .utf8)

        // Native messaging is how the shim reaches Bosk; user scripts are carried out through
        // WebKit's registered content scripts, which need scripting.
        var permissions = manifest["permissions"] as? [Any] ?? []
        let asked = Set(permissions.compactMap { $0 as? String })
        var added = addedPermissions(in: folder)
        for needed in ["nativeMessaging"] + (asked.contains("userScripts") ? ["scripting"] : [])
        where !asked.contains(needed) {
            permissions.append(needed)
            added.append(needed)
        }
        manifest["permissions"] = permissions
        if let list = try? JSONSerialization.data(withJSONObject: Array(Set(added)).sorted()) {
            try? list.write(to: folder.appending(path: addedFile))
        }

        // The background, whichever kind it is, gets the shim first. A classic service worker
        // gets it at the top of its own file; a module one imports it first, because its
        // imports run before anything written above them.
        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String, let path = inside(worker, of: folder),
               var source = try? String(contentsOf: path, encoding: .utf8) {
                // Already carrying one: take the old one off, so a newer shim takes its place.
                if source.hasPrefix(marker), let end = source.range(of: ender) {
                    source = String(source[end.upperBound...].drop { $0 == "\n" })
                }
                let first = "import \"/\(file)\";\n"
                while source.hasPrefix(first) { source.removeFirst(first.count) }
                let module = (background["type"] as? String) == "module"
                let script = try String(contentsOf: folder.appending(path: file), encoding: .utf8)
                try (module ? first + source : marker + "\n" + script + "\n" + ender + "\n" + source)
                    .write(to: path, atomically: true, encoding: .utf8)
            }
            // Scripts, alone or beside a worker: WebKit runs them as a page when a manifest
            // names both.
            if var scripts = background["scripts"] as? [String] {
                if scripts.first != file { scripts.insert(file, at: 0) }
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }

        // Content scripts too: there only Chrome's behavior is mended.
        if let entries = manifest["content_scripts"] as? [[String: Any]] {
            manifest["content_scripts"] = entries.map { entry -> [String: Any] in
                var entry = entry
                if var js = entry["js"] as? [String] {
                    if !js.contains(file) { js.insert(file, at: 0) }
                    entry["js"] = js
                }
                return entry
            }
        }

        let output = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try output.write(to: manifestURL, options: .atomic)

        // Every page it ships: popup, options, background page, side panel.
        let walker = files.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  ["html", "htm"].contains(url.pathExtension.lowercased()),
                  var html = try? String(contentsOf: url, encoding: .utf8),
                  !html.contains(file)
            else { continue }
            let tag = "<script src=\"/\(file)\"></script>"
            if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: tag, at: head.upperBound)
            } else {
                html = tag + html
            }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
        try? wanted.write(to: stampURL, atomically: true, encoding: .utf8)
    }

    /// The permissions `prepare` added to the manifest.
    public static func addedPermissions(in folder: URL) -> [String] {
        let url = folder.appending(path: addedFile)
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String] ?? []
    }

    /// A path a package names, resolved and kept inside its folder: `..` in a manifest is not a
    /// way out of the package, and neither is a symbolic link (the worker is written back over
    /// it, so a link to a file elsewhere would put that file's bytes in the package).
    public static func inside(_ name: String, of folder: URL) -> URL? {
        let path = folder.appending(path: name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              path.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return path
    }

    /// The shim as this extension gets it: with the events its code mentions, so its worker can
    /// take their listeners late, and with the scripts it ships, so a missing import fails at once.
    static func shim(for folder: URL, chromeVersion: String, verbose: Bool) -> String {
        var found = Set<String>()
        var scripts: [String] = []
        let pattern = try! NSRegularExpression(pattern: #"\.([a-zA-Z]+)\.(on[A-Z][A-Za-z]+)\b"#)
        let base = folder.standardizedFileURL.path
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "js" else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count))
            var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "x"
            // An empty one is marked: there is nothing to run in it.
            scripts.append((text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "-" : "") + path)
            guard url.lastPathComponent != file else { continue }
            // Not the shim's own words, in a worker that already carries it.
            if text.hasPrefix(marker), let end = text.range(of: ender) { text = String(text[end.upperBound...]) }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) else { continue }
                found.insert("\(text[a]).\(text[b])")
            }
        }
        func json(_ list: [String]) -> String {
            (try? JSONSerialization.data(withJSONObject: list.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return script.replacingOccurrences(of: "__BOSK_EVENTS__", with: json(Array(found)))
            .replacingOccurrences(of: "__BOSK_SCRIPTS__", with: json(scripts))
            .replacingOccurrences(of: "__BOSK_CHROME__", with: chromeVersion)
            .replacingOccurrences(of: "__BOSK_VERBOSE__", with: verbose ? "true" : "false")
    }
}
