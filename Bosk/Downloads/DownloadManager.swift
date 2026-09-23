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

    var hasRunningDownloads: Bool { items.contains { $0.state == .running } }

    func track(_ download: WKDownload) {
        download.delegate = self
        items.insert(Item(download: download), at: 0)
        progressObservations.append(download.progress.observe(\.fractionCompleted) { _, _ in
            MainActor.assumeIsolated { DownloadManager.shared.changed() }
        })
        changed()
    }

    func addObserver(_ owner: AnyObject, _ handler: @escaping () -> Void) {
        observers[ObjectIdentifier(owner)] = handler
    }

    func removeObserver(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
    }

    private func changed() {
        observers.values.forEach { $0() }
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
            destination = url
        } else {
            destination = Self.uniqueURL(in: folder, name: suggestedFilename)
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
    static func uniqueURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appending(path: name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
