import AppKit
import SwiftUI

/// Window > Tab Manager: each tab with the memory and CPU of its web process, updated every 2 seconds.
/// Tabs that one page opened can share a process; they show the same numbers and process ID.
/// The pages of saved web apps (Save as App) are tabs too, with the web app's name.
@MainActor
final class TabManagerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TabManagerWindowController()
    private let model = TabManagerModel()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: TabManagerView(model: model)))
        window.title = "Tab Manager"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 440))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("TabManager")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        model.start()
        showWindow(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) { model.stop() }
}

@MainActor
@Observable
final class TabManagerModel {
    struct Row: Identifiable {
        let id: UUID
        let tab: Tab
        let title: String
        let site: String
        let icon: NSImage?
        /// The saved web app that shows this tab; nil for a tab in a browser window.
        let appName: String?
        let pid: Int32?
        /// Nil while the tab sleeps.
        let memory: UInt64?
        /// Percent of one core. Nil for the first sample of a process.
        let cpu: Double?
        let isSelected: Bool

        var memorySort: UInt64 { memory ?? 0 }
        var cpuSort: Double { cpu ?? 0 }
        var pidSort: Int32 { pid ?? 0 }
    }

    var rows: [Row] = []
    var sortOrder = [KeyPathComparator(\Row.memorySort, order: .reverse)] {
        didSet { rows.sort(using: sortOrder) }
    }

    private var timer: Timer?
    /// The last CPU time of each process, to compute CPU use between two samples.
    private var lastSamples: [Int32: (cpuNanoseconds: UInt64, time: UInt64)] = [:]

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastSamples = [:]
    }

    func refresh() {
        let now = DispatchTime.now().uptimeNanoseconds
        var usages: [Int32: (memory: UInt64, cpu: Double?)] = [:]
        var samples: [Int32: (cpuNanoseconds: UInt64, time: UInt64)] = [:]
        var rows: [Row] = []
        let browserStores = (TabSleepManager.shared.storesProvider?() ?? []).map { (store: $0, appName: String?.none) }
        let webAppStores = WebAppHost.shared.sessions.map { (store: $0.store, appName: $0.appName ?? "Web App") }
        for (store, appName) in browserStores + webAppStores {
            for tab in store.allTabs {
                let pid = tab.webView.flatMap { WebProcessStats.pid($0) }
                if let pid, usages[pid] == nil, let usage = WebProcessStats.usage(pid) {
                    var cpu: Double?
                    if let last = lastSamples[pid], now > last.time, usage.cpuNanoseconds >= last.cpuNanoseconds {
                        cpu = Double(usage.cpuNanoseconds - last.cpuNanoseconds) / Double(now - last.time) * 100
                    }
                    usages[pid] = (usage.footprint, cpu)
                    samples[pid] = (usage.cpuNanoseconds, now)
                }
                let usage = pid.flatMap { usages[$0] }
                rows.append(Row(id: tab.id, tab: tab, title: tab.displayTitle, site: tab.url?.host() ?? "",
                                icon: tab.favicon, appName: appName, pid: pid, memory: usage?.memory, cpu: usage?.cpu,
                                isSelected: tab === store.selectedTab))
            }
        }
        lastSamples = samples
        self.rows = rows.sorted(using: sortOrder)
    }
}

struct TabManagerView: View {
    @Bindable var model: TabManagerModel

    var body: some View {
        Table(model.rows, sortOrder: $model.sortOrder) {
            TableColumn("Tab", value: \.title) { row in
                HStack(spacing: 6) {
                    if let icon = row.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(row.title).lineLimit(1)
                    if let appName = row.appName {
                        Text(appName).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help(row.site)
            }
            .width(min: 180, ideal: 300)
            TableColumn("Memory", value: \.memorySort) { row in
                Text(row.memory.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) }
                    ?? "Asleep")
                    .foregroundStyle(row.memory == nil ? .secondary : .primary)
                    .monospacedDigit()
            }
            .width(80)
            TableColumn("CPU", value: \.cpuSort) { row in
                Text(row.cpu.map { String(format: "%.1f%%", $0) } ?? "–").monospacedDigit()
            }
            .width(60)
            TableColumn("Process", value: \.pidSort) { row in
                Text(row.pid.map(String.init) ?? "–").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(60)
            TableColumn("") { row in
                HStack(spacing: 4) {
                    Button("Sleep") {
                        row.tab.sleep()
                        model.refresh()
                    }
                    // Sleep would leave the window with no page on screen.
                    .disabled(row.memory == nil || row.isSelected)
                    Button("Close") {
                        row.tab.store?.close(row.tab)
                        model.refresh()
                    }
                }
                .controlSize(.small)
            }
            .width(110)
        }
    }
}
