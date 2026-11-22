import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// File > Save as App…: makes a small app for the tab's site. The user chooses the app's name and
/// folder. The app is a copy of the helper inside Bosk (WebAppHelper), with the site, its own
/// bundle ID and the site's icon, signed for this Mac only (ad-hoc).
@MainActor
enum WebAppCreator {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func saveAsApp(_ tab: Tab, in window: NSWindow) {
        guard let url = tab.url, ["http", "https"].contains(url.scheme), !tab.isPrivate else { return }
        let panel = NSSavePanel()
        panel.title = "Save as App"
        panel.prompt = "Save"
        panel.message = "The app opens \(url.host() ?? url.absoluteString) in its own window, with its own Dock icon."
        panel.nameFieldLabel = "App name:"
        panel.nameFieldStringValue = suggestedName(for: tab)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canCreateDirectories = true
        let applications = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")
        try? FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        panel.directoryURL = applications
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            let name = destination.deletingPathExtension().lastPathComponent
            Task {
                do {
                    let icon = await bestIcon(for: tab)
                    try make(name: name, url: url, icon: icon, at: destination)
                    NSWorkspace.shared.open(destination)
                } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = "The app could not be saved"
                    alert.informativeText = error.localizedDescription
                    _ = await alert.beginSheetModal(for: window)
                }
            }
        }
    }

    private static func suggestedName(for tab: Tab) -> String {
        // Page titles are often long ("Inbox (3) - name@example.com - Mail"): the site's name is shorter.
        var host = tab.url?.host() ?? "Web App"
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let title = tab.title.trimmingCharacters(in: .whitespaces)
        return (!title.isEmpty && title.count <= 24 ? title : host).replacingOccurrences(of: "/", with: "-")
    }

    // MARK: The app

    private static func make(name: String, url: URL, icon: NSImage?, at destination: URL) throws {
        let fileManager = FileManager.default
        let template = Bundle.main.bundleURL.appending(path: "Contents/Helpers/Bosk Web App.app")
        guard fileManager.fileExists(atPath: template.path) else {
            throw Failure(errorDescription: "The web app template is missing from Bosk. Install Bosk again.")
        }
        // Saving over an app made earlier keeps its bundle ID, so macOS keeps its notification setting.
        let oldInfo = NSDictionary(contentsOf: destination.appending(path: "Contents/Info.plist")) as? [String: Any]
        let oldID = oldInfo?["BoskWebAppURL"] != nil ? oldInfo?["CFBundleIdentifier"] as? String : nil
        if fileManager.fileExists(atPath: destination.path) {
            // The save panel asked the user to replace it. To the Trash, so it can come back.
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: template, to: destination)
        removeQuarantine(in: destination)

        let infoURL = destination.appending(path: "Contents/Info.plist")
        guard var info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw Failure(errorDescription: "The web app template has no Info.plist.")
        }
        let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        info["CFBundleIdentifier"] = oldID ?? "com.brainpad.bosk.webapp.\(random)"
        info["CFBundleName"] = name
        info["CFBundleDisplayName"] = name
        info["BoskWebAppURL"] = url.absoluteString
        info["BoskSocketPath"] = WebAppHost.socketPath
        info["BoskHostBundleID"] = Bundle.main.bundleIdentifier
        if let icon {
            let resources = destination.appending(path: "Contents/Resources")
            try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
            try writeIcon(icon, to: resources.appending(path: "AppIcon.icns"))
            info["CFBundleIconFile"] = "AppIcon"
        }
        guard (info as NSDictionary).write(to: infoURL, atomically: true) else {
            throw Failure(errorDescription: "Bosk could not write the app's Info.plist.")
        }
        try sign(destination)
        // So the Dock and Finder show the new icon and name now.
        LSRegisterURL(destination as CFURL, true)
    }

    /// A copy keeps the extended attributes. A quarantine mark from Bosk's download would make
    /// macOS refuse the new app, because its signature is for this Mac only.
    private static func removeQuarantine(in app: URL) {
        removexattr(app.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            removexattr(file.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    /// The Info.plist changed, so the template's signature is no longer valid. An ad-hoc signature
    /// is for this Mac only; that is enough for an app made on this Mac.
    private static func sign(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", app.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure(errorDescription: "macOS could not sign the app. \(message)")
        }
    }

    // MARK: Icon

    /// The site's largest icon (often its 180 px apple-touch-icon). Bosk's saved favicons are only 64 px.
    private static func bestIcon(for tab: Tab) async -> NSImage? {
        let fallback = tab.favicon ?? FaviconStore.shared.cachedIcon(for: tab.url)
        guard let webView = tab.webView else { return fallback }
        let script = """
            [...document.querySelectorAll('link[rel~="icon"], link[rel^="apple-touch-icon"]')]
                .map(l => [l.href, l.getAttribute('sizes') || '', l.rel])
            """
        let links = (try? await webView.evaluateJavaScript(script)) as? [[String]] ?? []
        func size(_ link: [String]) -> Int {
            let sizes = link[1].lowercased().split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }
            if let largest = sizes.max() { return largest }
            if link[1].lowercased() == "any" { return 1024 }
            return link[2].hasPrefix("apple-touch-icon") ? 180 : 32
        }
        var candidates = links.filter { $0.count == 3 }.sorted { size($0) > size($1) }.compactMap { URL(string: $0[0]) }
        // Many sites have this file without a link to it.
        if let origin = tab.url.flatMap({ URL(string: "/apple-touch-icon.png", relativeTo: $0) }) {
            candidates.append(origin.absoluteURL)
        }
        for candidate in candidates.prefix(4) {
            guard let (data, response) = try? await URLSession.shared.data(from: candidate),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data), image.representations.contains(where: { $0.pixelsWide >= 96 }) else { continue }
            return image
        }
        return fallback
    }

    /// The site's icon on a macOS-style rounded square, as an .icns file.
    private static func writeIcon(_ image: NSImage, to url: URL) throws {
        let pixels = image.representations.map(\.pixelsWide).max() ?? 0
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, 6, nil) else {
            throw Failure(errorDescription: "Bosk could not make the app icon.")
        }
        for size in [16, 32, 128, 256, 512, 1024] {
            guard let cgImage = iconBitmap(image, size: size, fillsTile: pixels >= 96) else { continue }
            CGImageDestinationAddImage(destination, cgImage, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(errorDescription: "Bosk could not make the app icon.")
        }
    }

    /// A large icon fills the tile; a small one sits in the middle of a white tile, so it is not blurred.
    private static func iconBitmap(_ image: NSImage, size: Int, fillsTile: Bool) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = CGFloat(size) / 1024
        // The macOS icon grid: an 824 px tile in a 1024 px canvas.
        let tile = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        let path = CGPath(roundedRect: tile, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)
        context.addPath(path)
        context.clip()
        context.setFillColor(.white)
        context.fill(tile)
        let imageRect = fillsTile ? tile : tile.insetBy(dx: tile.width * 0.25, dy: tile.height * 0.25)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: imageRect)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
