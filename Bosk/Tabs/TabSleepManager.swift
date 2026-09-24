import BoskCore
import Foundation
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
            MainActor.assumeIsolated { TabSleepManager.shared.check(pressure: .normal) }
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
            // each question can wake a suspended page.
            let now = Date()
            let candidates = SleepPolicy.tabsToSleep(
                tabsByID.values.map { info(for: $0, isSelected: selectedIDs.contains($0.id), isPlayingMedia: false) },
                now: now, idleLimit: idleLimit,
                pressureIdleLimit: Defaults.tabSleepPressureIdleLimit, pressure: pressure)
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
            let ids = SleepPolicy.tabsToSleep(infos, now: Date(), idleLimit: idleLimit,
                                              pressureIdleLimit: Defaults.tabSleepPressureIdleLimit,
                                              pressure: pressure)
            for id in ids {
                // The user may have selected the tab while the media checks ran.
                guard let tab = tabsByID[id], tab !== tab.store?.selectedTab else { continue }
                tab.sleep()
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
