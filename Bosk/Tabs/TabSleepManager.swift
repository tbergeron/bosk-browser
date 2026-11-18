import AppKit
import BoskCore
import WebKit

/// Puts idle tabs to sleep (see `SleepPolicy`). It checks on a timer, and at once when
/// macOS reports memory pressure.
@MainActor
final class TabSleepManager {
    static let shared = TabSleepManager()

    /// All windows' tab stores. AppDelegate sets it.
    var storesProvider: (() -> [TabStore])?

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var isChecking = false
    /// Memory pressure reported during a check. macOS reports each change one time only.
    private var pendingPressure: SleepPolicy.MemoryPressure?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Defaults.tabSleepCheckInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                TabSleepManager.shared.enforceMemoryLimit()
                TabSleepManager.shared.check(pressure: .normal)
            }
        }
        timer?.tolerance = Defaults.tabSleepCheckInterval / 4
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let event = source.data
                TabSleepManager.shared.check(pressure: event.contains(.critical) ? .critical : .warning)
            }
        }
        source.activate()
        pressureSource = source
    }

    func check(pressure: SleepPolicy.MemoryPressure) {
        // Off in Settings means off, also under memory pressure.
        guard Preferences.sleepsTabs else { return }
        guard !isChecking else {
            if pressure == .critical || (pressure == .warning && pendingPressure == nil) { pendingPressure = pressure }
            return
        }
        isChecking = true
        Task {
            defer {
                isChecking = false
                if let next = pendingPressure {
                    pendingPressure = nil
                    check(pressure: next)
                }
            }
            let idleLimit = Defaults.tabSleepIdleLimitOverride ?? Preferences.tabSleepAfter
            let stores = storesProvider?() ?? []
            var tabsByID: [UUID: Tab] = [:]
            var selectedIDs: Set<UUID> = []
            for store in stores {
                for tab in store.allTabs where !tab.isAsleep { tabsByID[tab.id] = tab }
                if let selected = store.selectedTab { selectedIDs.insert(selected.id) }
            }
            // First without media: only tabs that could sleep are asked about media, because
            // each question can wake a suspended page. All idle tabs, because under a warning
            // only one sleeps, and the oldest can be playing media.
            let now = Date()
            let candidates = SleepPolicy.idleTabs(
                tabsByID.values.map { info(for: $0, isSelected: selectedIDs.contains($0.id), isPlayingMedia: false) },
                now: now, idleLimit: idleLimit, pressure: pressure)
            guard !candidates.isEmpty else { return }
            // Ask the pages at the same time: each answer can take up to the timeout.
            let infos = await withTaskGroup(of: SleepPolicy.TabInfo.self) { group in
                for id in candidates {
                    guard let tab = tabsByID[id] else { continue }
                    group.addTask { await self.info(for: tab, isSelected: false) }
                }
                var infos: [SleepPolicy.TabInfo] = []
                for await info in group { infos.append(info) }
                return infos
            }
            let ids = SleepPolicy.tabsToSleep(infos, now: Date(), idleLimit: idleLimit, pressure: pressure)
            for id in ids {
                // The user may have selected the tab while the media checks ran.
                guard let tab = tabsByID[id], tab !== tab.store?.selectedTab else { continue }
                tab.sleep()
            }
        }
    }

    /// Tab ID → the web process the user chose to keep after the memory warning. A new process warns again.
    private var ignoredMemoryWarnings: [UUID: Int32] = [:]

    /// Stops pages that run out of control (`SleepPolicy.memoryLimit`). It runs also when tab sleep
    /// is off in Settings: a page that fills memory and swap slows the whole Mac.
    func enforceMemoryLimit() {
        var tabsByID: [UUID: Tab] = [:]
        var processTabs: [SleepPolicy.ProcessTab] = []
        var footprints: [Int32: UInt64] = [:]
        for store in storesProvider?() ?? [] {
            for tab in store.allTabs {
                guard let webView = tab.webView, let pid = WebProcessStats.pid(webView) else { continue }
                tabsByID[tab.id] = tab
                if footprints[pid] == nil { footprints[pid] = WebProcessStats.usage(pid)?.footprint ?? 0 }
                processTabs.append(.init(id: tab.id, pid: pid, isSelected: tab === store.selectedTab,
                                         isCapturing: webView.cameraCaptureState != .none
                                             || webView.microphoneCaptureState != .none))
            }
        }
        let limit = Defaults.memoryLimitOverride.map { UInt64($0) << 20 } ?? SleepPolicy.memoryLimit
        let over = SleepPolicy.overMemoryLimit(processTabs, footprints: footprints, limit: limit)
        for id in over.sleep { tabsByID[id]?.sleep() }
        for id in over.warn {
            guard let tab = tabsByID[id], let pid = tab.webView.flatMap({ WebProcessStats.pid($0) }),
                  ignoredMemoryWarnings[id] != pid else { continue }
            warn(tab, pid: pid, footprint: footprints[pid] ?? 0)
        }
    }

    /// Asks the user about the tab on screen. Reload ends its web process; WebKit then reloads the
    /// page in a new process (`webViewWebContentProcessDidTerminate`).
    private func warn(_ tab: Tab, pid: Int32, footprint: UInt64) {
        guard let window = tab.webView?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        let size = ByteCountFormatter.string(fromByteCount: Int64(footprint), countStyle: .memory)
        alert.messageText = "This page uses \(size) of memory"
        alert.informativeText = "\(tab.displayTitle) uses much more memory than a normal page, and it can slow down "
            + "your Mac. Reload the page to give the memory back."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Ignore")
        alert.beginSheetModal(for: window) { [weak tab] response in
            MainActor.assumeIsolated {
                guard let tab else { return }
                if response == .alertFirstButtonReturn {
                    // The page can have a new process now: end only the one the user was asked about.
                    if tab.webView.flatMap({ WebProcessStats.pid($0) }) == pid { kill(pid, SIGKILL) }
                } else {
                    TabSleepManager.shared.ignoredMemoryWarnings[tab.id] = pid
                }
            }
        }
    }

    private func info(for tab: Tab, isSelected: Bool) async -> SleepPolicy.TabInfo {
        let media: WKMediaPlaybackState? = if let webView = tab.webView { await mediaState(webView) } else { nil }
        return info(for: tab, isSelected: isSelected, isPlayingMedia: media == .playing)
    }

    private func info(for tab: Tab, isSelected: Bool, isPlayingMedia: Bool) -> SleepPolicy.TabInfo {
        let webView = tab.webView
        let capturing = webView.map { $0.cameraCaptureState != .none || $0.microphoneCaptureState != .none } ?? false
        return SleepPolicy.TabInfo(id: tab.id, lastActive: tab.lastActive, isSelected: isSelected,
                                   isAsleep: tab.isAsleep, isPlayingMedia: isPlayingMedia,
                                   isCapturing: capturing, hasUnsentInput: tab.hasUnsentInput,
                                   isPinned: tab.isPinned)
    }

    /// `requestMediaPlaybackState` can wait without end for a background web view whose
    /// process WebKit has suspended. A suspended page plays no media, so no answer in time
    /// counts as "not playing".
    private func mediaState(_ webView: WKWebView) async -> WKMediaPlaybackState {
        await withCheckedContinuation { continuation in
            var answered = false
            let answer = { (state: WKMediaPlaybackState) in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: state)
            }
            webView.requestMediaPlaybackState { state in MainActor.assumeIsolated { answer(state) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { answer(.none) } }
        }
    }
}
