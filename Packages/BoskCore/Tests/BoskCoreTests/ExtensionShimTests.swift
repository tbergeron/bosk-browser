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

    @Test("A worker path outside the package is not read or written")
    func workerOutsideFolderIsLeftAlone() throws {
        #expect(ExtensionShim.inside("../outside.js", of: folder) == nil)
        #expect(ExtensionShim.inside("/bg.js", of: folder)?.lastPathComponent == "bg.js")
    }
}
