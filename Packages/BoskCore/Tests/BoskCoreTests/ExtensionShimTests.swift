import Foundation
import JavaScriptCore
import Testing
@testable import BoskCore

/// Bosk adds its shim to each extension's files. If the shim is missing from a place, the
/// extension there runs without the Chrome APIs and the WebKit fixes (Bitwarden freezes, Dark
/// Reader gets stuck). If it is added twice, the extension runs it twice and breaks.
struct ExtensionShimTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "shim-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func write(_ text: String, to name: String) throws {
        let url = folder.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    func manifest() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "manifest.json"))) as? [String: Any] ?? [:]
    }

    func worker(_ extra: [String: Any] = [:]) throws {
        var background: [String: Any] = ["service_worker": "bg.js"]
        background.merge(extra) { $1 }
        let data = try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "background": background,
                                                               "permissions": ["storage"]])
        try data.write(to: folder.appending(path: "manifest.json"))
        try write("chrome.runtime.onMessage.addListener(() => {});\n", to: "bg.js")
    }

    @Test("The worker runs the shim before its own code, so the fixes are in place when it starts")
    func workerGetsShimFirst() throws {
        try worker()
        try ExtensionShim.prepare(folder, chromeVersion: "141.0.0.0")
        let source = try read("bg.js")
        #expect(source.hasPrefix(ExtensionShim.marker))
        #expect(source.hasSuffix("chrome.runtime.onMessage.addListener(() => {});\n"))
        // The events its code mentions are listed, so late listeners still work.
        #expect(source.contains(#"["runtime.onMessage"]"#))
    }

    @Test("A new Bosk version replaces the old shim instead of adding a second copy")
    func preparingAgainReplaces() throws {
        try worker()
        try ExtensionShim.prepare(folder, chromeVersion: "141.0.0.0")
        try ExtensionShim.prepare(folder, chromeVersion: "142.0.0.0")
        let source = try read("bg.js")
        #expect(source.components(separatedBy: ExtensionShim.marker).count == 2)
        #expect(source.contains("142.0.0.0"))
        #expect(!source.contains("Chrome/141.0.0.0"))
    }

    @Test("A module worker imports the shim, because its imports run before any code above them")
    func moduleWorkerImports() throws {
        try worker(["type": "module"])
        try ExtensionShim.prepare(folder, chromeVersion: "141.0.0.0")
        try ExtensionShim.prepare(folder, chromeVersion: "142.0.0.0")
        let source = try read("bg.js")
        #expect(source.hasPrefix("import \"/bosk-shim.js\";\nchrome.runtime"))
        #expect(try read("bosk-shim.js").contains("142.0.0.0"))
    }

    @Test("Content scripts and extension pages get the shim first, and only one time")
    func contentScriptsAndPages() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "manifest_version": 3,
            "content_scripts": [["matches": ["<all_urls>"], "js": ["a.js", "b.js"]]],
        ])
        try data.write(to: folder.appending(path: "manifest.json"))
        try write("<html><head><title>x</title></head></html>", to: "popup/index.html")
        try ExtensionShim.prepare(folder, chromeVersion: "141.0.0.0")
        try ExtensionShim.prepare(folder, chromeVersion: "142.0.0.0")
        let scripts = try manifest()["content_scripts"] as? [[String: Any]]
        #expect(scripts?.first?["js"] as? [String] == ["bosk-shim.js", "a.js", "b.js"])
        #expect(try read("popup/index.html") == #"<html><head><script src="/bosk-shim.js"></script><title>x</title></head></html>"#)
    }

    /// WebKit gives each web process its own copy of each content script, one for each content
    /// script entry and granted host pattern: 7 copies of the shim in each tab of the Debug profile.
    /// A script with a character above U+00FF is kept as UTF-16, 2 bytes a character, so those
    /// copies were 1.9 MB a tab instead of 0.95 MB. In the shim, write "-" or "—", not "—".
    @Test("The shim WebKit reads is Latin-1, so each tab's copies of it take 1 byte a character")
    func shimIsLatin1() throws {
        try worker()
        try ExtensionShim.prepare(folder, chromeVersion: "141.0.0.0")
        let shim = try read("bosk-shim.js")
        #expect(shim.unicodeScalars.allSatisfy { $0.value <= 0xFF })
    }

    @Test("A Debug build's shim reports console errors, and a release build's shim does not")
    func verboseOnlyWhenAsked() throws {
        try worker()
        try ExtensionShim.prepare(folder, chromeVersion: "141.0.0.0")
        #expect(try read("bosk-shim.js").contains("if (false && root.console)"))
        try ExtensionShim.prepare(folder, chromeVersion: "141.0.0.0", verbose: true)
        #expect(try read("bosk-shim.js").contains("if (true && root.console)"))
    }

    @Test("nativeMessaging is added so the shim can reach Bosk, and recorded so the install prompt does not show it")
    func nativeMessagingAdded() throws {
        try worker()
        try ExtensionShim.prepare(folder, chromeVersion: "141.0.0.0")
        #expect(try manifest()["permissions"] as? [String] == ["storage", "nativeMessaging"])
        #expect(ExtensionShim.addedPermissions(in: folder) == ["nativeMessaging"])
    }

    @Test("A package cannot claim that Bosk added one of the permissions it asks for")
    func freshIgnoresPackagedRecord() throws {
        try worker()
        try write(#"["tabs"]"#, to: ".bosk-added")
        try ExtensionShim.prepare(folder, chromeVersion: "141.0.0.0", fresh: true)
        #expect(ExtensionShim.addedPermissions(in: folder) == ["nativeMessaging"])
    }

    /// Runs the prepared shim in JavaScriptCore with a stub `chrome` whose `storage.local` calls
    /// named in `failing` reject with `error`. Calls get twice and set once, and returns the
    /// native messages the shim sent.
    func storageReports(error: String, failing: Set<String> = ["get", "set"],
                        protocol scheme: String = "webkit-extension:") throws -> [String] {
        try worker()
        try ExtensionShim.prepare(folder, chromeVersion: "141.0.0.0")
        let context = try #require(JSContext())
        context.evaluateScript("""
        var sent = [];
        var ev = () => ({ addListener() {}, removeListener() {}, hasListener() { return false; } });
        globalThis.location = { protocol: "\(scheme)", pathname: "/popup/index.html", origin: "x" };
        globalThis.chrome = {
          runtime: { id: "x", getManifest: () => ({ manifest_version: 3 }), getURL: (p) => "x/" + p,
            sendNativeMessage: (app, m) => { sent.push(m.api); return Promise.resolve({ value: null }); },
            sendMessage: () => Promise.resolve(undefined), onMessage: ev(), onConnect: ev() },
          storage: { onChanged: ev(), local: { onChanged: ev() } },
        };
        var failing = \((try? String(data: JSONSerialization.data(withJSONObject: failing.sorted()), encoding: .utf8)) ?? "[]");
        for (const name of ["get", "set"]) chrome.storage.local[name] = () => failing.includes(name)
          ? Promise.reject(new Error(\(String(reflecting: error)))) : Promise.resolve({});
        """)
        context.evaluateScript(try read("bosk-shim.js"))
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        context.evaluateScript(#"""
        chrome.storage.local.get("a").catch(() => {});
        chrome.storage.local.get("b").catch(() => {});
        chrome.storage.local.set({ c: 1 }).catch(() => {});
        """#)
        return context.evaluateScript("sent").toArray() as? [String] ?? []
    }

    @Test("When WebKit cannot open an extension's storage, Bosk is told once, so the spinning popup gets a warning")
    func brokenStorageIsReported() throws {
        let sent = try storageReports(
            error: "Invalid call to browser.storage.local.get(). Failed to open extension storage database because of an invalid schema version.")
        #expect(sent == ["storage.broken"])
    }

    @Test("A failed write alone is told too: with its folder unreadable, WebKit failed only Bitwarden's writes")
    func brokenWritesAreReported() throws {
        let sent = try storageReports(
            error: "Invalid call to browser.storage.local.set(). Failed to open extension storage database.",
            failing: ["set"])
        #expect(sent == ["storage.broken"])
    }

    @Test("A usual storage error, or one in a content script, gives no warning, so the warning is never false")
    func otherStorageErrorsAreNotReported() throws {
        #expect(try storageReports(error: "Invalid call: key must be a string.").isEmpty)
        #expect(try storageReports(error: "Failed to open extension storage database", protocol: "https:").isEmpty)
    }

    /// Runs the prepared shim as an extension page, with stub events that share one prototype,
    /// as WebKit's do. The page adds listeners, then `pagehide` comes with `persisted`.
    /// Returns how many listeners the stub events still hold.
    func listenersLeftAfterPagehide(persisted: Bool) throws -> Int {
        try worker()
        try ExtensionShim.prepare(folder, chromeVersion: "141.0.0.0")
        let context = try #require(JSContext())
        context.evaluateScript("""
        function Ev() { this.held = new Set(); }
        Ev.prototype.addListener = function (f) { this.held.add(f); };
        Ev.prototype.removeListener = function (f) { this.held.delete(f); };
        Ev.prototype.hasListener = function (f) { return this.held.has(f); };
        var pagehide = [];
        globalThis.document = {};
        globalThis.addEventListener = (type, f) => { if (type === "pagehide") pagehide.push(f); };
        globalThis.location = { protocol: "webkit-extension:", pathname: "/popup/index.html", origin: "x", href: "x/popup/index.html" };
        globalThis.chrome = {
          runtime: { id: "x", getManifest: () => ({ manifest_version: 3 }), getURL: (p) => "x/" + p,
            sendNativeMessage: () => Promise.resolve({ value: null }),
            sendMessage: () => Promise.resolve(undefined), onMessage: new Ev(), onConnect: new Ev() },
          tabs: { onUpdated: new Ev() },
          storage: { onChanged: new Ev() },
        };
        var events = [chrome.runtime.onMessage, chrome.runtime.onConnect, chrome.tabs.onUpdated, chrome.storage.onChanged];
        """)
        context.evaluateScript(try read("bosk-shim.js"))
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        context.evaluateScript("""
        chrome.runtime.onMessage.addListener(() => {});
        chrome.tabs.onUpdated.addListener(() => {});
        chrome.storage.onChanged.addListener(() => {});
        const removed = () => {};
        chrome.tabs.onUpdated.addListener(removed);
        chrome.tabs.onUpdated.removeListener(removed);
        """)
        #expect(context.evaluateScript("events.reduce((n, e) => n + e.held.size, 0)").toInt32() >= 3)
        context.evaluateScript("pagehide.forEach((f) => f({ persisted: \(persisted) }))")
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return Int(context.evaluateScript("events.reduce((n, e) => n + e.held.size, 0)").toInt32())
    }

    @Test("A closed extension page leaves no listener with WebKit, which would keep the whole page (30 MB a Bitwarden popup)")
    func closedPageLetsGoOfListeners() throws {
        #expect(try listenersLeftAfterPagehide(persisted: false) == 0)
    }

    @Test("A page kept in the back-forward cache keeps its listeners, so it still works when it comes back")
    func cachedPageKeepsListeners() throws {
        #expect(try listenersLeftAfterPagehide(persisted: true) >= 3)
    }

    @Test("A content script becomes ASCII, because one other character doubles its copy in each web process")
    func contentScriptBecomesASCII() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "manifest_version": 3, "content_scripts": [["matches": ["<all_urls>"], "js": ["a.js"]]],
        ])
        try data.write(to: folder.appending(path: "manifest.json"))
        try write("// 图形\nvar text = '•';\n", to: "a.js")
        try ExtensionShim.prepare(folder, chromeVersion: "1")
        let script = try read("a.js")
        #expect(script.utf8.allSatisfy { $0 < 0x80 })
        #expect(script.contains("\\u2022"))
    }

    @Test("An escaped script does the same as the original, so the extension does not change")
    func escapedScriptMeansTheSame() throws {
        let source = #"[`é ${1} ☃`, "😀", /[☃😀]/u.test("😀"), /☃/.test("☃"), ({ é: 2 }).é]"#
        let escaped = try #require(ExtensionShim.asciiScript(source))
        #expect(escaped.utf8.allSatisfy { $0 < 0x80 })
        let original = try #require(JSContext().evaluateScript(source).toArray() as? [AnyHashable])
        let context = try #require(JSContext())
        let result = try #require(context.evaluateScript(escaped).toArray() as? [AnyHashable])
        #expect(context.exception == nil)
        #expect(result == original)
    }

    @Test("A script stays as it is if an escape could change or break it", arguments: [
        #""\☃""#,                  // A backslash before the character.
        "var a\u{00A0}= 1;",       // A space outside a string is not the same as its escape.
        "/* x\u{2028} */ var é;",  // A line end.
        "\u{FEFF}var é;",          // A byte order mark.
        "var \u{1D49C} = 1;",      // A letter past U+FFFF, as an identifier.
        "String.raw`☃`",            // The raw text of a template would show the escape.
    ])
    func riskyScriptIsLeftAlone(source: String) {
        #expect(ExtensionShim.asciiScript(source) == nil)
    }

    @Test("A worker path outside the package is not read or written")
    func workerOutsideFolderIsLeftAlone() throws {
        #expect(ExtensionShim.inside("../outside.js", of: folder) == nil)
        #expect(ExtensionShim.inside("/bg.js", of: folder)?.lastPathComponent == "bg.js")
    }
}
