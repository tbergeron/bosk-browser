import BoskCore
import Foundation

/// The pinned sites. They are the same in every window; each window keeps its own
/// tab for each entry (see `TabStore.syncPinnedTabs`).
@MainActor
final class PinnedStore {
    static let shared = PinnedStore()

    private(set) var entries: [PinnedEntry] = []
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    func restore(_ entries: [PinnedEntry]) {
        self.entries = entries
    }

    @discardableResult
    func pin(url: URL, title: String, at index: Int? = nil) -> PinnedEntry {
        let entry = PinnedEntry(url: url, title: title)
        entries.insert(entry, at: min(index ?? entries.count, entries.count))
        changed()
        return entry
    }

    func unpin(_ id: UUID) {
        entries.removeAll { $0.id == id }
        changed()
    }

    func move(_ id: UUID, to index: Int) {
        guard let from = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: min(index, entries.count))
        changed()
    }

    func entry(_ id: UUID) -> PinnedEntry? {
        entries.first { $0.id == id }
    }

    func addObserver(_ owner: AnyObject, _ handler: @escaping () -> Void) {
        observers[ObjectIdentifier(owner)] = handler
    }

    func removeObserver(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
    }

    private func changed() {
        observers.values.forEach { $0() }
        SessionStore.shared.setNeedsSave()
    }
}
