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
    /// Encodes and writes in order, off the main thread. The write at quit waits for an
    /// earlier write, so an older session cannot replace it.
    private let writeQueue = DispatchQueue(label: "Bosk.SessionStore", qos: .utility)

    private init() {
        let directory = Defaults.dataDirectory
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
            guard let session = self.snapshotProvider?() else { return }
            let url = self.fileURL
            self.writeQueue.async { Self.write(session, to: url) }
        }
    }

    /// Writes now, and waits. Use it when the app quits.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let session = snapshotProvider?() else { return }
        let url = fileURL
        writeQueue.sync { Self.write(session, to: url) }
    }

    private nonisolated static func write(_ session: Session, to url: URL) {
        guard let data = try? session.encoded() else { return }
        try? data.write(to: url, options: .atomic)
    }
}
