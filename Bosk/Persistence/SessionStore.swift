import BoskCore
import Foundation

/// Saves windows, tabs and pinned entries to a JSON file, so they come back on relaunch.
@MainActor
final class SessionStore {
    static let shared = SessionStore()

    /// Builds the current session. AppDelegate sets it.
    var snapshotProvider: (() -> Session)?

    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?

    private init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Bosk", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "session.json")
    }

    func load() -> Session? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try Session.decode(data)
        } catch {
            // Keep the bad file for inspection instead of writing over it later.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("broken.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("Bosk: session file did not load (%@). Moved it to %@.", "\(error)", backup.path)
            return nil
        }
    }

    /// Saves after a short delay. Many changes in a row cause one write.
    func setNeedsSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Defaults.sessionSaveDelay)
            guard let self, !Task.isCancelled else { return }
            self.pendingSave = nil
            guard let data = self.encodedSnapshot() else { return }
            let url = self.fileURL
            await Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }.value
        }
    }

    /// Writes now, on this thread. Use it when the app quits.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        if let data = encodedSnapshot() { try? data.write(to: fileURL, options: .atomic) }
    }

    private func encodedSnapshot() -> Data? {
        guard let session = snapshotProvider?() else { return nil }
        return try? session.encoded()
    }
}
