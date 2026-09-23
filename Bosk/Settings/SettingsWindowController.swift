import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The Settings window. Only three things: default browser, default page zoom, extensions.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: .init())))
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate()
    }
}

/// State for the settings view, read from Bosk's stores.
@MainActor
@Observable
final class SettingsModel {
    struct ExtensionRow: Identifiable {
        let id: String
        let name: String
        let version: String
        var enabled: Bool
    }

    var isDefaultBrowser = false
    var defaultZoom = PageZoom.defaultZoom
    var extensions: [ExtensionRow] = []
    var message: String?

    init() {
        refresh()
        ExtensionManager.shared.addObserver(self) { [weak self] in self?.refresh() }
    }

    func refresh() {
        isDefaultBrowser = Self.checkDefaultBrowser()
        extensions = ExtensionManager.shared.records.map { record in
            let context = ExtensionManager.shared.contexts[record.id]
            return ExtensionRow(id: record.id,
                                name: context?.webExtension.displayName ?? record.fileName,
                                version: context?.webExtension.version ?? "",
                                enabled: record.enabled)
        }
    }

    private static func checkDefaultBrowser() -> Bool {
        guard let web = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: web) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks macOS to use Bosk for http and https links. macOS shows its own confirmation.
    func makeDefaultBrowser() async {
        do {
            for scheme in ["http", "https"] {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                                   toOpenURLsWithScheme: scheme)
            }
            message = nil
        } catch {
            message = "macOS did not change the default browser: \(error.localizedDescription)"
        }
        refresh()
    }

    func setDefaultZoom(_ zoom: Double) {
        PageZoom.defaultZoom = zoom
        defaultZoom = zoom
    }

    func addExtension() {
        let panel = NSOpenPanel()
        panel.message = "Choose an unpacked extension folder, or a .zip or .crx file."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip, UTType(filenameExtension: "crx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await ExtensionManager.shared.install(from: url, in: nil)
                message = nil
            } catch {
                message = "The extension did not install: \(error.localizedDescription)"
            }
        }
    }

    func setEnabled(_ enabled: Bool, id: String) {
        Task { await ExtensionManager.shared.setEnabled(enabled, id: id) }
    }

    func remove(id: String) {
        ExtensionManager.shared.remove(id: id)
    }
}

struct SettingsView: View {
    @State var model: SettingsModel

    var body: some View {
        Form {
            Section("Default browser") {
                if model.isDefaultBrowser {
                    Label("Bosk is your default browser", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Open links from other apps in Bosk")
                        Spacer()
                        Button("Make Default") { Task { await model.makeDefaultBrowser() } }
                    }
                }
            }

            Section("Page zoom") {
                Picker("Default zoom for all pages", selection: Binding(
                    get: { model.defaultZoom },
                    set: { model.setDefaultZoom($0) })) {
                    ForEach(PageZoom.defaultChoices, id: \.self) { Text(PageZoom.label($0)).tag($0) }
                }
                Text("⌘+ and ⌘− change one tab. ⌘0 goes back to this default.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Extensions") {
                if model.extensions.isEmpty {
                    Text("No extensions. Open a Chrome Web Store page and click “Add to Bosk”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.extensions) { item in
                    HStack {
                        Toggle(isOn: Binding(get: { item.enabled },
                                             set: { model.setEnabled($0, id: item.id) })) {
                            VStack(alignment: .leading) {
                                Text(item.name)
                                Text(item.version).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Remove", role: .destructive) { model.remove(id: item.id) }
                    }
                }
                Button("Add Extension from Disk…") { model.addExtension() }
            }

            if let message = model.message {
                Text(message).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
