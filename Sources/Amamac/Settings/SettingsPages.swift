import AppKit
import KeyboardShortcuts
import SwiftUI
import AmamacCore

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage private var showTrayIcon: Bool
    @AppStorage private var startPlayingOnAdd: Bool
    @AppStorage private var autoScroll: Bool
    @AppStorage private var inhibitSleep: Bool
    @AppStorage private var pauseOnSleep: Bool

    init(env: AppEnvironment) {
        let d = env.settings.defaults
        typealias K = AppSettings.Key
        _showTrayIcon = AppStorage(wrappedValue: true, K.showTrayIcon, store: d)
        _startPlayingOnAdd = AppStorage(wrappedValue: false, K.startPlayingOnAdd, store: d)
        _autoScroll = AppStorage(wrappedValue: true, K.autoScrollPlaylist, store: d)
        _inhibitSleep = AppStorage(wrappedValue: true, K.inhibitSleep, store: d)
        _pauseOnSleep = AppStorage(wrappedValue: true, K.pauseOnSleep, store: d)
    }

    var body: some View {
        Form {
            Section("Desktop") {
                Toggle("Show Amamac in the menu bar", isOn: $showTrayIcon)
                Text("Click the menu bar icon to show or hide the window, right-click for playback controls, scroll to change the volume and middle-click to pause.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Playlist") {
                Toggle("Start playing when tracks are added while stopped", isOn: $startPlayingOnAdd)
                Toggle("Keep the playing track in view", isOn: $autoScroll)
            }
            Section("Power") {
                Toggle("Keep the Mac from sleeping while music plays", isOn: $inhibitSleep)
                Toggle("Pause playback when the Mac goes to sleep", isOn: $pauseOnSleep)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Local Collection

@MainActor
@Observable
final class CollectionSettingsModel {
    let env: AppEnvironment
    private(set) var folders: [CollectionFolder] = []
    var selection: Set<String> = []

    init(env: AppEnvironment) {
        self.env = env
        reload()
    }

    func reload() { folders = env.collectionFolders }

    func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Collection"
        guard panel.runModal() == .OK else { return }
        let paths = folders.map(\.path) + panel.urls.map(\.path).filter { p in !folders.contains { $0.path == p } }
        env.setCollectionFolders(paths)
        env.settings.set(true, AppSettings.Key.firstRunDone)
        reload()
        env.scanCollection()
    }

    func removeSelected() {
        guard !selection.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(selection.count == 1 ? "this folder" : "these folders") from the collection?"
        alert.informativeText = "The files stay on disk; their tracks and statistics leave the collection."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        env.setCollectionFolders(folders.map(\.path).filter { !selection.contains($0) })
        selection = []
        reload()
        env.scanCollection()
    }

    func setWatch(_ folder: CollectionFolder, _ on: Bool) {
        try? env.database.writer.write { db in
            try db.execute(sql: "UPDATE collection_folder SET watch = ? WHERE path = ?", arguments: [on, folder.path])
        }
        env.startWatching()
        reload()
    }
}

struct CollectionSettingsView: View {
    @State private var model: CollectionSettingsModel

    init(env: AppEnvironment) { _model = State(initialValue: CollectionSettingsModel(env: env)) }

    var body: some View {
        Form {
            Section {
                List(selection: $model.selection) {
                    ForEach(model.folders, id: \.path) { folder in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(folder.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Toggle("Watch", isOn: Binding(get: { folder.watch }, set: { model.setWatch(folder, $0) }))
                                .toggleStyle(.checkbox)
                                .help("Pick up changes in this folder as they happen")
                        }
                        .tag(folder.path)
                    }
                }
                .frame(height: 140)
                .overlay {
                    if model.folders.isEmpty { Text("No folders yet. Add the folders that hold your music.").foregroundStyle(.secondary) }
                }
                HStack {
                    Button { model.add() } label: { Image(systemName: "plus") }.help("Add Folder…")
                    Button { model.removeSelected() } label: { Image(systemName: "minus") }.help("Remove Folder").disabled(model.selection.isEmpty)
                    Spacer()
                    Button("Update Collection") { model.env.scanCollection() }
                    Button("Full Rescan") { model.env.scanCollection(full: true) }
                }
                .buttonStyle(.bordered)
            } header: {
                Text("Collection Folders")
            } footer: {
                Text("Tracks in folders that are not reachable (an unplugged drive, say) are kept with their statistics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Metadata

struct MetadataSettingsView: View {
    let env: AppEnvironment
    @AppStorage private var autoFetchCovers: Bool
    @AppStorage private var writeStatistics: Bool
    @AppStorage private var wikipediaLanguage: String

    static let languages: [(String, String)] = [
        ("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"), ("nl", "Nederlands"),
        ("pt", "Português"), ("sv", "Svenska"), ("no", "Norsk"), ("da", "Dansk"), ("fi", "Suomi"), ("is", "Íslenska"),
        ("pl", "Polski"), ("cs", "Čeština"), ("ru", "Русский"), ("uk", "Українська"), ("ja", "日本語"), ("zh", "中文"), ("ko", "한국어"),
    ]

    init(env: AppEnvironment) {
        self.env = env
        let d = env.settings.defaults
        typealias K = AppSettings.Key
        _autoFetchCovers = AppStorage(wrappedValue: false, K.autoFetchCovers, store: d)
        _writeStatistics = AppStorage(wrappedValue: false, K.writeStatisticsToFile, store: d)
        _wikipediaLanguage = AppStorage(wrappedValue: "en", K.wikipediaLanguage, store: d)
    }

    var body: some View {
        Form {
            Section("Covers") {
                Toggle("Fetch missing covers for the playing album", isOn: $autoFetchCovers)
                Text("Looks the album up on MusicBrainz and the Cover Art Archive, then the iTunes Store. Tools › Cover Manager fetches covers for many albums at once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Statistics") {
                Toggle("Write ratings and play counts into the files", isOn: $writeStatistics)
                Text("Uses the FMPS tags other players understand, so statistics survive moving files to another collection.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Apple Music") {
                    Button("Import Statistics…") { AppDelegate.shared?.importAppleMusicStatistics(nil) }
                }
            }
            Section("Wikipedia") {
                Picker("Article language", selection: $wikipediaLanguage) {
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: wikipediaLanguage) { _, new in
            // The Wikipedia applet listens for this notification.
            env.settings.set(new, AppSettings.Key.wikipediaLanguage)
        }
    }
}

// MARK: - Notifications (OSD)

struct NotificationSettingsView: View {
    let env: AppEnvironment
    @AppStorage private var osdEnabled: Bool
    @AppStorage private var osdDuration: Int
    @AppStorage private var translucent: Bool
    @AppStorage private var fontScale: Int
    @AppStorage private var hideWhenFullscreen: Bool
    @AppStorage private var screen: Int
    @AppStorage private var textColor: String
    @AppStorage private var systemNotifications: Bool
    @State private var previewing = false
    @State private var notificationsDenied = false

    init(env: AppEnvironment) {
        self.env = env
        let d = env.settings.defaults
        typealias K = AppSettings.Key
        _osdEnabled = AppStorage(wrappedValue: true, K.osdEnabled, store: d)
        _osdDuration = AppStorage(wrappedValue: 5000, K.osdDuration, store: d)
        _translucent = AppStorage(wrappedValue: true, K.osdTranslucent, store: d)
        _fontScale = AppStorage(wrappedValue: 115, K.osdFontScale, store: d)
        _hideWhenFullscreen = AppStorage(wrappedValue: true, K.osdHideWhenFullscreen, store: d)
        _screen = AppStorage(wrappedValue: 0, K.osdScreen, store: d)
        _textColor = AppStorage(wrappedValue: "#FFFFFF", K.osdTextColor, store: d)
        _systemNotifications = AppStorage(wrappedValue: false, K.systemNotifications, store: d)
    }

    private var osd: OSDController? { AppDelegate.shared?.desktop?.osd }

    var body: some View {
        Form {
            Section("On-Screen Display") {
                Toggle("Show the on-screen display", isOn: $osdEnabled)
                Group {
                    LabeledContent("Duration") {
                        HStack {
                            Slider(value: Binding(get: { Double(osdDuration) / 1000 }, set: { osdDuration = Int($0.rounded()) * 1000 }), in: 1...15)
                                .frame(width: 180)
                            Text("\(osdDuration / 1000) s").monospacedDigit().frame(width: 36, alignment: .trailing)
                        }
                    }
                    LabeledContent("Text size") {
                        HStack {
                            Slider(value: Binding(get: { Double(fontScale) }, set: { fontScale = Int(($0 / 5).rounded()) * 5 }), in: 70...200)
                                .frame(width: 180)
                            Text("\(fontScale)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    ColorPicker("Text colour", selection: Binding(get: { Color(nsColor: NSColor(hex: textColor) ?? .white) },
                                                                set: { textColor = NSColor($0).hexString }), supportsOpacity: false)
                    Toggle("Translucent background", isOn: $translucent)
                    Picker("Screen", selection: $screen) {
                        Text("Screen with the Amamac window").tag(0)
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { i, s in Text(s.localizedName).tag(i + 1) }
                    }
                    Toggle("Hide while another app is in full screen", isOn: $hideWhenFullscreen)
                    LabeledContent("Position") {
                        Button(previewing ? "Done" : "Show Preview…") {
                            previewing.toggle()
                            osd?.setPreviewing(previewing)
                        }
                        .disabled(osd == nil)
                    }
                    .help("Drag the preview to where the display should appear.")
                }
                .disabled(!osdEnabled)
            }
            Section {
                Toggle("Post a notification when the track changes", isOn: Binding(get: { systemNotifications }, set: { on in
                    guard on else { systemNotifications = false; return }
                    Task {
                        let granted = await TrackNotifier.requestAuthorization()
                        systemNotifications = granted
                        notificationsDenied = !granted
                    }
                }))
                if notificationsDenied {
                    Text("Notifications are turned off for Amamac in System Settings › Notifications.")
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Notification Center")
            } footer: {
                Text("Shown only while Amamac is in the background.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear {
            if previewing {
                previewing = false
                osd?.setPreviewing(false)
            }
        }
    }
}

// MARK: - Internet

struct InternetSettingsView: View {
    let env: AppEnvironment
    @AppStorage private var updateMinutes: Int
    @AppStorage private var podcastFolder: String
    @State private var cacheCleared = false

    init(env: AppEnvironment) {
        self.env = env
        let d = env.settings.defaults
        _updateMinutes = AppStorage(wrappedValue: 60, AppSettings.Key.podcastUpdateMinutes, store: d)
        _podcastFolder = AppStorage(wrappedValue: "", AppSettings.Key.podcastFolder, store: d)
    }

    static let services: [(String, String)] = [
        ("LRCLIB", "lyrics"), ("Wikipedia and Wikidata", "the Wikipedia applet"),
        ("MusicBrainz and Cover Art Archive", "tag lookups and covers"), ("iTunes Search", "covers and the podcast directory"),
        ("radio-browser.info", "internet radio"),
    ]

    var body: some View {
        Form {
            Section("Podcasts") {
                Picker("Check for new episodes", selection: $updateMinutes) {
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                    Text("Every 2 hours").tag(120)
                    Text("Every 6 hours").tag(360)
                    Text("Once a day").tag(1440)
                }
                .onChange(of: updateMinutes) { env.podcasts.startAutoUpdate() }
                LabeledContent("Download folder") {
                    HStack {
                        Text(PodcastController.downloadFolder(env).path(percentEncoded: false))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Text("A new folder applies to new downloads; existing episodes stay where they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(Self.services, id: \.0) { service in
                    LabeledContent(service.0) { Text(service.1).foregroundStyle(.secondary) }
                }
                LabeledContent("Web cache") {
                    Button(cacheCleared ? "Cleared" : "Clear Cache") {
                        try? FileManager.default.removeItem(at: env.cacheDirectory.appendingPathComponent("http"))
                        try? FileManager.default.createDirectory(at: env.cacheDirectory.appendingPathComponent("http"), withIntermediateDirectories: true)
                        cacheCleared = true
                    }
                    .disabled(cacheCleared)
                }
            } header: {
                Text("Online Services")
            } footer: {
                Text("Amamac identifies itself as “\(Amamac.userAgent)” and sends only what a lookup needs: titles, artists and album names. No account or personal information is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        podcastFolder = url.path
    }
}

// MARK: - Shortcuts

struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(HotKeys.all, id: \.0) { name, title in
                    KeyboardShortcuts.Recorder(LocalizedStringKey(title), name: name)
                }
            } header: {
                Text("Global Shortcuts")
            } footer: {
                HStack {
                    Text("These work in every app. Click a field and press the new combination; press Delete to clear it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { KeyboardShortcuts.reset(HotKeys.all.map(\.0)) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
