import AppKit
import BoskCore
import CryptoKit
import WebKit

/// Site icons, one per host, cached on disk as 64 px PNG files.
@MainActor
final class FaviconStore {
    static let shared = FaviconStore()

    private let memory = NSCache<NSString, NSImage>()
    private let directory: URL
    private var inFlight: Set<String> = []

    private static let findIconsScript = """
        [...document.querySelectorAll('link[rel~="icon"], link[rel^="apple-touch-icon"]')]
            .map(l => ({ href: l.href, sizes: l.getAttribute('sizes') || '', rel: l.rel }))
        """

    private init() {
        memory.countLimit = 300
        directory = URL.cachesDirectory.appending(path: "Bosk/Favicons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cachedIcon(for url: URL?) -> NSImage? {
        guard let host = url?.host() else { return nil }
        if let image = memory.object(forKey: host as NSString) { return image }
        guard let image = NSImage(contentsOf: fileURL(for: host)) else { return nil }
        image.size = NSSize(width: 32, height: 32)
        memory.setObject(image, forKey: host as NSString)
        return image
    }

    /// Finds the page's icon after it loads, downloads it, and gives it to the tab.
    func refresh(for tab: Tab) {
        guard let webView = tab.webView, let pageURL = webView.url, let host = pageURL.host(),
              !inFlight.contains(host) else { return }
        inFlight.insert(host)
        Task {
            defer { inFlight.remove(host) }
            let candidates = await Self.candidates(in: webView)
            guard let iconURL = FaviconPicker.pick(from: candidates, pageURL: pageURL),
                  let image = await Self.download(iconURL) else { return }
            memory.setObject(image, forKey: host as NSString)
            if let png = image.pngData { try? png.write(to: fileURL(for: host), options: .atomic) }
            if tab.url?.host() == host { tab.favicon = image }
        }
    }

    private static func candidates(in webView: WKWebView) async -> [FaviconPicker.Candidate] {
        guard let result = try? await webView.evaluateJavaScript(findIconsScript),
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let href = item["href"] as? String, let url = URL(string: href) else { return nil }
            return .init(url: url, sizes: item["sizes"] as? String ?? "", rel: item["rel"] as? String ?? "")
        }
    }

    private static func download(_ url: URL) async -> NSImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let source = NSImage(data: data), source.isValid else { return nil }
        return source.resized(toPixels: 64)
    }

    private func fileURL(for host: String) -> URL {
        let hash = SHA256.hash(data: Data(host.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: hash + ".png")
    }
}

private extension NSImage {
    /// A square bitmap at `pixels` size, shown at half that size in points.
    func resized(toPixels pixels: Int) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: pixels / 2, height: pixels / 2))
        image.addRepresentation(rep)
        return image
    }

    var pngData: Data? {
        (representations.first as? NSBitmapImageRep)?.representation(using: .png, properties: [:])
    }
}
