import BoskCore
import Foundation

/// The bookmarks, one flat list in a JSON file of its own. Not in session.json: a session
/// file that does not load is moved away, and the bookmarks must not go with it.
@MainActor
final class BookmarkStore {
    static let shared = BookmarkStore()

    private(set) var entries: [Bookmark] = []
    private let fileURL = Defaults.dataDirectory.appending(path: "bookmarks.json")

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            entries = try JSONDecoder().decode([Bookmark].self, from: data)
        } catch {
            // Keep the bad file for inspection instead of writing over it later.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("broken.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("Bosk: bookmarks file did not load (%@). Moved it to %@.", "\(error)", backup.path)
        }
    }

    /// Adds a bookmark at the end. A page that is already bookmarked is not added again.
    func add(url: URL, title: String) {
        guard bookmark(for: url) == nil else { return }
        entries.append(Bookmark(url: url, title: title))
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func bookmark(for url: URL) -> Bookmark? {
        entries.first { $0.url == url }
    }

    /// Writes now. The file is small and changes only when the user adds or removes a bookmark,
    /// and a write on this thread keeps the writes in order.
    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Bosk: bookmarks were not saved: %@", "\(error)")
        }
    }
}
