import AppKit
import WebKit

/// Downloads go to the folder chosen in Settings (~/Downloads at first), or to where the
/// user says for each file. The list lives until Bosk quits.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    final class Item {
        enum State { case running, finished, failed }
        let download: WKDownload
        var filename = ""
        var destination: URL?
        var state = State.running

        init(download: WKDownload) { self.download = download }
    }

    private(set) var items: [Item] = []
    private var observers: [ObjectIdentifier: () -> Void] = [:]
    private var progressObservations: [NSKeyValueObservation] = []
    private var progressUpdatePending = false

    var hasRunningDownloads: Bool { items.contains { $0.state == .running } }

    func track(_ download: WKDownload) {
        download.delegate = self
        items.insert(Item(download: download), at: 0)
        // Progress changes for each received chunk, maybe not on the main thread.
        progressObservations.append(download.progress.observe(\.fractionCompleted) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { DownloadManager.shared.progressChanged() } }
        })
        changed()
    }

    func addObserver(_ owner: AnyObject, _ handler: @escaping () -> Void) {
        observers[ObjectIdentifier(owner)] = handler
    }

    func removeObserver(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
    }

    /// Moves the file to the Trash (the user can get it back) and takes it off the list.
    func delete(_ item: Item) {
        if let url = item.destination { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        items.removeAll { $0 === item }
        changed()
    }

    private func changed() {
        observers.values.forEach { $0() }
    }

    /// Updates the UI at most 4 times a second for progress.
    private func progressChanged() {
        guard !progressUpdatePending else { return }
        progressUpdatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                self.progressUpdatePending = false
                self.changed()
            }
        }
    }

    private func item(for download: WKDownload) -> Item? {
        items.first { $0.download === download }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let folder = Preferences.downloadFolder
        let destination: URL
        if Preferences.asksWhereToSave {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.directoryURL = folder
            guard await panel.begin() == .OK, let url = panel.url else {
                // Returning nil cancels the download; it leaves the list.
                items.removeAll { $0.download === download }
                changed()
                return nil
            }
            // The panel asked the user to replace a file with this name; WebKit does not
            // write over a file.
            try? FileManager.default.removeItem(at: url)
            destination = url
        } else {
            // WebKit makes the file later, so also skip names that running downloads will use.
            let taken = Set(items.filter { $0.state == .running }.compactMap { $0.destination?.path })
            destination = Self.uniqueURL(in: folder, name: suggestedFilename, excluding: taken)
        }
        if let item = item(for: download) {
            item.filename = destination.lastPathComponent
            item.destination = destination
        }
        changed()
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        changed()
        // Makes the Downloads stack in the Dock bounce, as Safari does.
        if let path = item.destination?.path {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        item(for: download)?.state = .failed
        changed()
    }

    /// "file.zip", then "file 2.zip", "file 3.zip", …
    static func uniqueURL(in directory: URL, name: String, excluding taken: Set<String> = []) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appending(path: name)
        var number = 2
        while taken.contains(candidate.path) || FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
