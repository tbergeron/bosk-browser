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
        guard Preferences.sleepsTabs, !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            let stores = storesProvider?() ?? []
            var tabsByID: [UUID: Tab] = [:]
            var selectedIDs: Set<UUID> = []
            for store in stores {
                for tab in store.allTabs where !tab.isAsleep { tabsByID[tab.id] = tab }
                if let selected = store.selectedTab { selectedIDs.insert(selected.id) }
            }
            // Ask all pages at the same time: each answer can take up to the timeout.
            let infos = await withTaskGroup(of: SleepPolicy.TabInfo.self) { group in
                for tab in tabsByID.values {
                    let isSelected = selectedIDs.contains(tab.id)
                    group.addTask { await self.info(for: tab, isSelected: isSelected) }
                }
                var infos: [SleepPolicy.TabInfo] = []
                for await info in group { infos.append(info) }
                return infos
            }
            let ids = SleepPolicy.tabsToSleep(infos, now: Date(), idleLimit: Defaults.tabSleepIdleLimit,
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
        let webView = tab.webView
        let media: WKMediaPlaybackState? = if let webView { await mediaState(webView) } else { nil }
        let capturing = webView.map { $0.cameraCaptureState != .none || $0.microphoneCaptureState != .none } ?? false
        return SleepPolicy.TabInfo(id: tab.id, lastActive: tab.lastActive, isSelected: isSelected,
                                   isAsleep: tab.isAsleep, isPlayingMedia: media == .playing,
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
