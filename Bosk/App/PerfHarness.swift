#if DEBUG
import AppKit

/// Debug builds only. Launch with `-BoskPerfTest YES` and Bosk folds and unfolds the sidebar
/// and switches tabs by itself, so Instruments can measure hitches without input noise.
/// See scripts/measure-hitches.sh.
@MainActor
enum PerfHarness {
    /// `-BoskInstallExtension <path>`: installs a folder, .zip or .crx at launch (it still asks).
    static func installExtensionIfRequested(_ controller: BrowserWindowController) {
        guard let path = UserDefaults.standard.string(forKey: "BoskInstallExtension") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            do {
                try await ExtensionManager.shared.install(from: URL(fileURLWithPath: path), in: controller.window)
            } catch {
                NSLog("Bosk: test install failed: %@", "\(error)")
            }
        }
    }

    /// `-BoskInstallWebStoreIDs id1,id2`: installs Chrome Web Store extensions at launch.
    static func installWebStoreExtensionsIfRequested(_ controller: BrowserWindowController) {
        guard let ids = UserDefaults.standard.string(forKey: "BoskInstallWebStoreIDs") else { return }
        Task { @MainActor in
            for id in ids.split(separator: ",").map(String.init) {
                do {
                    try await ExtensionManager.shared.installFromWebStore(extensionID: id, in: controller.window)
                    NSLog("Bosk: test install of %@ done", id)
                } catch {
                    NSLog("Bosk: test install of %@ failed: %@", id, "\(error)")
                }
            }
        }
    }

    static func runIfRequested(_ controller: BrowserWindowController) {
        guard UserDefaults.standard.bool(forKey: "BoskPerfTest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            for _ in 0..<6 {
                controller.toggleSidebar(nil)
                try? await Task.sleep(for: .seconds(1))
            }
            for _ in 0..<8 {
                controller.selectNextTab(nil)
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }
}
#endif
