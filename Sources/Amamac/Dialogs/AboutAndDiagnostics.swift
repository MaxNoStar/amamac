import AmamacBase
import AmamacDatabase
import AmamacPlayback
import AppKit
import SwiftUI

enum AboutPanel {
    static func show() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let credits = NSMutableAttributedString(string: """
            A music player for macOS on Apple silicon, with the layout and features of Amarok 2/3.

            Amamac is not affiliated with KDE or the Amarok project. It reuses no Amarok code or \
            artwork. Help › Acknowledgements lists the open-source components it builds on.
            """, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: Amamac.appName,
            .applicationVersion: version,
            .version: "build \(build)",
            .credits: credits,
        ])
    }
}

// MARK: - Acknowledgements

enum AcknowledgementsWindow {
    static func show() {
        SingleWindow.show("AcknowledgementsWindow") {
            let text = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The notices file is missing from this build."
            let scroll = NSTextView.scrollableTextView()
            let textView = scroll.documentView as! NSTextView
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.string = text
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Acknowledgements"
            w.contentView = scroll
            return w
        }
    }
}

// MARK: - Diagnostics

/// A plain-text report for bug reports: versions, paths, collection size and audio state.
/// Nothing in it identifies the user beyond the home-folder paths.
@MainActor
enum Diagnostics {
    static func report(env: AppEnvironment) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var arch = "unknown"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #endif
        let counts = (try? env.database.totals()) ?? LibraryDatabase.Totals()
        let dbSize = ["collection.sqlite", "collection.sqlite-wal"].reduce(Int64(0)) { total, name in
            total + ((try? FileManager.default.attributesOfItem(atPath: env.dataDirectory.appendingPathComponent(name).path)[.size] as? Int64) ?? 0)
        }
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: Bundle.main.bundlePath + "/Contents/Frameworks")) ?? []
        let player = env.player
        let device = AudioDevices.outputDevices().first { $0.id == player.local.outputDeviceID }?.name ?? "unknown"
        let settings = env.settings
        var lines = [
            "Amamac \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(arch)",
            "",
            "Data folder: \(env.dataDirectory.path)",
            "Database: \(ByteCountFormatter.string(fromByteCount: dbSize, countStyle: .file))",
            "Collection folders: \(env.collectionFolders.map(\.path).joined(separator: ", "))",
            "Tracks: \(counts.tracks), albums: \(counts.albums), tracks played: \(counts.playedTracks)",
            "Saved playlists: \(counts.playlists), podcasts: \(counts.podcasts)",
            "Podcast downloads: \(PodcastController.downloadFolder(env).path)",
            "",
            "Playback: \(player.state), engine: \(player.backend)",
            "Output device: \(device)",
            "Replay Gain: \(settings.replayGainMode.displayName), pre-amp \(settings.double(AppSettings.Key.replayGainPreamp)) dB",
            "Equalizer: \(env.equalizer.enabled ? "on, \(env.equalizer.presetName)" : "off")",
            "Volume: \(player.volume)%\(player.isMuted ? " (muted)" : "")",
            "Playlist: \(env.playlist.count) items, progression \(env.navigator.progression.rawValue)",
            "Dynamic mode: \(env.dynamicMode.active?.name ?? "off")",
            "",
            "Bundled frameworks (\(frameworks.count)): \(frameworks.sorted().joined(separator: ", "))",
        ]
        lines.append("User-Agent: \(Amamac.userAgent)")
        return lines.joined(separator: "\n")
    }
}

struct DiagnosticsView: View {
    let env: AppEnvironment
    @State private var report = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Include this report when describing a problem. It lists versions, folders and settings, not your music.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(report)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Show Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([env.dataDirectory]) }
                Spacer()
                Button("Refresh") { report = Diagnostics.report(env: env) }
                Button(copied ? "Copied" : "Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 640, height: 460)
        .onAppear { report = Diagnostics.report(env: env) }
    }
}

enum DiagnosticsWindow {
    static func show(env: AppEnvironment) {
        SingleWindow.show("DiagnosticsWindow") {
            let w = NSWindow(contentViewController: NSHostingController(rootView: DiagnosticsView(env: env)))
            w.title = "Diagnostics"
            w.styleMask = [.titled, .closable, .miniaturizable]
            return w
        }
    }
}

// MARK: - Help

/// A one-page guide: the layout, the filter syntax and the shortcuts.
struct HelpView: View {
    private struct Row: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    private let playback = [
        Row(keys: "Space", action: "Play / Pause"), Row(keys: "⌘.", action: "Stop"), Row(keys: "⌥⌘← / ⌥⌘→", action: "Previous / Next track"),
        Row(keys: "← / →", action: "Seek (⌘ short, ⇧ long steps)"), Row(keys: "⌘↑ / ⌘↓", action: "Volume"), Row(keys: "⌘D", action: "Queue the selected track"),
        Row(keys: "⌃⌥U", action: "Edit the queue"), Row(keys: "⌘J", action: "Search the playlist"), Row(keys: "⌥⌘F", action: "Search the collection"),
        Row(keys: "⌘L", action: "Show the playing track"), Row(keys: "⌥⌘1–3", action: "Show or hide a pane"), Row(keys: "⌥⌘E", action: "Equalizer"),
    ]

    private let filters = [
        Row(keys: "beatles", action: "Any field contains “beatles”"), Row(keys: "artist:beatles", action: "Artist contains “beatles”"),
        Row(keys: "year:>1990 year:<2000", action: "Both conditions (space means AND)"), Row(keys: "genre:jazz OR genre:blues", action: "Either condition"),
        Row(keys: "-genre:pop", action: "Exclude matches"), Row(keys: "rating:>3.5", action: "Rated above three and a half stars"),
        Row(keys: "added:<2w", action: "Added in the last two weeks"), Row(keys: "playcount:0", action: "Never played"),
        Row(keys: "length:>600", action: "Longer than ten minutes"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("The Window") {
                    Text("""
                        **Media Sources** (left) browses your collection, playlists, files, internet radio and podcasts. \
                        Drag anything onto the playlist, or drop it on the **Context** pane (middle) to choose how it is added. \
                        The Context pane shows applets for the playing track: details, Wikipedia, other albums and a spectrum analyzer. \
                        The **Playlist** (right) groups tracks by album and can be sorted, searched and saved.
                        """)
                    Text("Add music with Tools › Collection Folders…, or drop folders on the playlist.")
                }
                section("Collection Filters") {
                    Text("Type in the collection search field; the same syntax works in dynamic playlists and the playlist generator.")
                    table(filters)
                }
                section("Keyboard") { table(playback) }
                section("Global Shortcuts") {
                    Text("These work in every app and can be changed in Settings › Shortcuts. By default they use ⌃⌥: P plays or pauses, ← and → change tracks, = and − change the volume, M mutes, O shows the on-screen display and 1–5 rate the playing track.")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 600, height: 560)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.bold())
            content()
        }
    }

    private func table(_ rows: [Row]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.keys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    Text(row.action)
                }
            }
        }
    }
}

enum HelpWindow {
    static func show() {
        SingleWindow.show("HelpWindow") {
            let w = NSWindow(contentViewController: NSHostingController(rootView: HelpView()))
            w.title = "Amamac Help"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            return w
        }
    }
}
