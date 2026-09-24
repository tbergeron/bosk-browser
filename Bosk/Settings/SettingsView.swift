import AppKit
import SwiftUI

/// The Settings window content: a list of panes on the left, the chosen pane on the right.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", tabs = "Tabs", extensions = "Extensions",
             downloads = "Downloads", privacy = "Privacy", about = "About"

        var id: Self { self }

        var symbol: String {
            switch self {
            case .general: "macwindow"
            case .tabs: "rectangle.split.3x1"
            case .extensions: "puzzlepiece.extension"
            case .downloads: "arrow.down.circle"
            case .privacy: "hand.raised"
            case .about: "info.circle"
            }
        }
    }

    @State var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.pane.rawValue).font(.title.bold())
                    switch model.pane {
                    case .general: GeneralPane(model: model)
                    case .tabs: TabsPane(model: model)
                    case .extensions: ExtensionsPane(model: model)
                    case .downloads: DownloadsPane(model: model)
                    case .privacy: PrivacyPane(model: model)
                    case .about: AboutPane(model: model)
                    }
                    if let message = model.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 36)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The title bar is transparent: the sidebar and the divider go up to the top edge.
        .ignoresSafeArea()
        .frame(width: 740, height: 560)
        .onChange(of: model.pane) { model.message = nil }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings").font(.headline).padding(.horizontal, 10).padding(.bottom, 10)
            ForEach(Pane.allCases) { item in
                Button { model.pane = item } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(model.pane == item ? Color.primary.opacity(0.08) : .clear))
                }
                .buttonStyle(.plain)
                .fontWeight(model.pane == item ? .semibold : .regular)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .frame(width: 200)
        .background(Color.primary.opacity(0.03))
    }
}

// MARK: Shared parts

/// A rounded card. Its rows get dividers between them.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews) { subview in
                    subview
                    if subview.id != subviews.last?.id { Divider().padding(.leading, 16) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// A title, an optional line of help under it, and a control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private extension View {
    /// The rounded outline buttons of the settings rows.
    func pillButton() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule)
    }
}

// MARK: Panes

private struct GeneralPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Default browser",
                        subtitle: model.isDefaultBrowser ? "Links from other apps open in Bosk"
                                                         : "Open links from other apps in Bosk") {
                if model.isDefaultBrowser {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    Button("Make Default") { Task { await model.makeDefaultBrowser() } }.pillButton()
                }
            }
            SettingsRow(title: "Appearance", subtitle: "Light, dark, or what the Mac uses — pages follow it too") {
                Picker("Appearance", selection: Binding(get: { model.appearance },
                                                        set: { model.setAppearance($0) })) {
                    Text("Light").tag(Preferences.Appearance.light)
                    Text("Dark").tag(Preferences.Appearance.dark)
                    Text("System").tag(Preferences.Appearance.system)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingsRow(title: "Page zoom", subtitle: "⌘+ and ⌘− change one tab. ⌘0 goes back to this default.") {
                Picker("Page zoom", selection: Binding(get: { model.defaultZoom },
                                                       set: { model.setDefaultZoom($0) })) {
                    ForEach(PageZoom.defaultChoices, id: \.self) { Text(PageZoom.label($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow(title: "Correct spelling as you type", subtitle: "The macOS autocorrect, inside pages") {
                Toggle("Correct spelling as you type", isOn: Binding(get: { model.correctsSpelling },
                                                                     set: { model.setCorrectsSpelling($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

private struct TabsPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Sleep tabs you aren't using",
                        subtitle: "After half an hour away they come back where you left them. "
                            + "Pinned tabs, sound, calls and anything typed stay awake.") {
                Toggle("Sleep tabs you aren't using", isOn: Binding(get: { model.sleepsTabs },
                                                                    set: { model.setSleepsTabs($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

private struct ExtensionsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Add from the Chrome Web Store")
                    Spacer()
                    Button("Open the Store") { model.openStore() }.pillButton()
                }
                HStack {
                    TextField("Paste a link to an extension, or its ID", text: $model.storeInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.addFromStore() }
                    Button("Add") { model.addFromStore() }
                        .pillButton()
                        .disabled(model.storeExtensionID == nil)
                }
                Text("Or find it in the store and press Add to Bosk on its page.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
        }

        if !model.extensions.isEmpty {
            SettingsCard {
                ForEach(model.extensions) { item in
                    HStack(spacing: 12) {
                        Group {
                            if let icon = item.icon {
                                Image(nsImage: icon).resizable()
                            } else {
                                Image(systemName: "puzzlepiece.extension").resizable().scaledToFit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            HStack(spacing: 0) {
                                Text(item.details)
                                if !item.warnings.isEmpty {
                                    Text(" · ")
                                    Text(item.warnings.count == 1 ? "1 warning" : "\(item.warnings.count) warnings")
                                        .help(item.warnings.joined(separator: "\n\n"))
                                }
                            }
                            .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            if item.canReload { Button("Reload") { model.reload(id: item.id) } }
                            Button("Remove", role: .destructive) { model.remove(id: item.id) }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        Toggle(item.name, isOn: Binding(get: { item.enabled },
                                                        set: { model.setEnabled($0, id: item.id) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }

        SettingsCard {
            SettingsRow(title: "Load an unpacked extension",
                        subtitle: "A folder with a manifest.json — your own, or one exported from another "
                            + "browser. Reload in its … menu picks up what you changed in it since.") {
                Button("Choose…") { model.addExtension() }.pillButton()
            }
        }
    }
}

private struct DownloadsPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Save to", subtitle: (model.downloadFolder.path as NSString).abbreviatingWithTildeInPath) {
                Button("Change…") { model.chooseDownloadFolder() }.pillButton()
            }
            SettingsRow(title: "Ask where to save each file") {
                Toggle("Ask where to save each file", isOn: Binding(get: { model.asksWhereToSave },
                                                                    set: { model.setAsksWhereToSave($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

private struct PrivacyPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Block ads and trackers",
                        subtitle: "Use the shield in the address bar to allow ads on one site") {
                Toggle("Block ads and trackers", isOn: Binding(get: { model.blocksAds },
                                                               set: { model.setBlocksAds($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsRow(title: "Filter lists", subtitle: "EasyList and EasyPrivacy, updated each week") {
                Text(model.adListsUpdated?.formatted(date: .abbreviated, time: .shortened) ?? "Not downloaded yet")
                    .foregroundStyle(.secondary)
            }
        }

        SettingsCard {
            SettingsRow(title: "History", subtitle: "Every address you have been to") {
                Button("Clear") { model.clearHistory() }.pillButton()
            }
            SettingsRow(title: "Cookies and sign-ins", subtitle: "Signs you out of every site") {
                Button("Sign out of everything") { model.signOutOfEverything() }.pillButton()
            }
            SettingsRow(title: "Cache", subtitle: "Only what was fetched to draw pages") {
                Button("Clear") { model.clearCache() }.pillButton()
            }
        }
    }
}

private struct AboutPane: View {
    let model: SettingsModel

    /// Only shortcuts that are in the main menu (MainMenu.swift).
    private let shortcuts: [(String, String)] = [
        ("Search commands", "⌘P"),
        ("Address", "⌘L"),
        ("New, close, reopen tab", "⌘T  ⌘W  ⇧⌘T"),
        ("Next and previous tab", "⌃⇥  ⌃⇧⇥"),
        ("Go to tab 1 to 8, last tab", "⌘1 … ⌘9"),
        ("Search tabs", "⇧⌘A"),
        ("Show history", "⌘Y"),
        ("Bookmark page, show bookmarks", "⌘D  ⌥⌘B"),
        ("Fold the sidebar", "⌘S"),
        ("Show or hide reader", "⇧⌘R"),
        ("Find in page", "⌘F"),
        ("Back and forward", "⌘[  ⌘]"),
        ("Zoom in, out, actual size", "⌘+  ⌘−  ⌘0"),
    ]

    /// The libraries in Bosk (project.yml and Resources/Reader), with their links.
    private let libraries: [(name: String, use: String, links: [(String, String)])] = [
        ("Defuddle", "Reader mode · by Steph Ango · MIT License",
         [("Website", "https://stephango.com"), ("GitHub", "https://github.com/kepano/defuddle")]),
        ("Sparkle", "App updates · MIT License",
         [("Website", "https://sparkle-project.org"), ("GitHub", "https://github.com/sparkle-project/Sparkle")]),
    ]

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bosk").font(.title2.bold())
                Text("by Tommy Bergeron · version \(model.version)").foregroundStyle(.secondary)
            }
        }

        SettingsCard {
            SettingsRow(title: "Updates",
                        subtitle: Updater.isConfigured ? "Checked once a day on its own" : "Not set up in this build") {
                Button("Check now") { model.checkForUpdates() }.pillButton().disabled(!Updater.isConfigured)
            }
            SettingsRow(title: "Found something wrong?", subtitle: "Opens a new GitHub issue with the version already in it") {
                Button("Send Feedback") { model.sendFeedback() }.pillButton()
            }
        }

        SettingsCard {
            ForEach(shortcuts, id: \.0) { name, keys in
                SettingsRow(title: name) {
                    Text(keys).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }

        SettingsCard {
            ForEach(libraries, id: \.name) { library in
                SettingsRow(title: library.name, subtitle: library.use) {
                    HStack(spacing: 6) {
                        ForEach(library.links, id: \.0) { title, link in
                            Button(title) { model.open(URL(string: link)!) }.pillButton()
                        }
                    }
                }
            }
        }
    }
}
