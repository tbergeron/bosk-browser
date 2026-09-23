#if DEBUG
import AppKit
import WebKit

/// Debug builds only. Writes the process IDs of Bosk and its WebKit helper processes to
/// ~/Library/Caches/Bosk/processes.json every 2 seconds, for scripts/measure-memory.sh.
/// WebKit starts its helpers through launchd, so they are not child processes of Bosk.
/// The `_…Identifier` properties are private WebKit API; they are read only in Debug builds.
@MainActor
enum ProcessReport {
    private static var timer: Timer?
    /// Milliseconds from process start to the first window on screen.
    private static var launchMilliseconds: Int?

    /// Call when the first window frame is committed.
    static func recordLaunchTime() {
        launchMilliseconds = millisecondsSinceProcessStart()
    }

    private static func millisecondsSinceProcessStart() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Int((Date().timeIntervalSince1970 - started) * 1000)
    }

    static func start(stores: @escaping @MainActor () -> [TabStore]) {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { write(stores()) }
        }
    }

    private static func write(_ stores: [TabStore]) {
        let webViews = stores.flatMap(\.allTabs).compactMap(\.webView)
        let web = Set(webViews.compactMap { pid($0, "_webProcessIdentifier") })
        let gpu = Set(webViews.compactMap { pid($0, "_gpuProcessIdentifier") })
        let network = pid(WKWebsiteDataStore.default(), "_networkProcessIdentifier")
        let report: [String: Any] = [
            "app": ProcessInfo.processInfo.processIdentifier,
            "web": web.sorted(),
            "gpu": gpu.sorted(),
            "network": network.map { [$0] } ?? [],
            "awakeTabs": webViews.count,
            "awakeTitles": stores.flatMap(\.allTabs).filter { !$0.isAsleep }.map(\.displayTitle),
            "tabs": stores.flatMap(\.allTabs).count,
            "launchMilliseconds": launchMilliseconds ?? -1,
            "extensions": ExtensionManager.shared.loadedContexts.map { context in
                [
                    "name": context.webExtension.displayName ?? "?",
                    "version": context.webExtension.version ?? "?",
                    "manifestVersion": context.webExtension.manifestVersion,
                    "errors": (context.webExtension.errors + context.errors).map(\.localizedDescription),
                ] as [String: Any]
            },
        ]
        let url = URL.cachesDirectory.appending(path: "Bosk/processes.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func pid(_ object: NSObject, _ key: String) -> Int32? {
        guard object.responds(to: NSSelectorFromString(key)),
              let value = object.value(forKey: key) as? NSNumber, value.int32Value > 0 else { return nil }
        return value.int32Value
    }
}
#endif
