import AmamacModels
import AppKit
import SwiftUI

final class LyricsAppletController: Applet {
    let kind = AppletKind.lyrics
    let contentView: NSView
    private let model: LyricsAppletModel

    init(env: AppEnvironment) {
        model = LyricsAppletModel(env: env)
        contentView = HostedAppletView(rootView: LyricsApplet(model: model, player: env.player))
    }

    func setActive(_ active: Bool) {
        model.isActive = active
        if active { model.load() }
    }

    func makeConfigurationView() -> AnyView? {
        AnyView(LyricsSettingsView(model: model))
    }
}

@MainActor
@Observable
final class LyricsAppletModel {
    enum Status: Equatable {
        case nothingPlaying, loading, loaded, notFound, instrumental, stream, failed(String)
    }

    private(set) var status = Status.nothingPlaying
    private(set) var text = ""
    private(set) var lines: [LyricsLine] = []
    private(set) var synced = false
    private(set) var source = ""
    private(set) var heading = ""
    var isEditing = false
    var draft = ""
    var fontSize: Double {
        didSet { env.settings.set(fontSize, AppSettings.Key.lyricsFontSize) }
    }

    @ObservationIgnored var isActive = false
    @ObservationIgnored let env: AppEnvironment
    @ObservationIgnored private var loadedItem: PlaylistItemID?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(env: AppEnvironment) {
        self.env = env
        fontSize = env.settings.double(AppSettings.Key.lyricsFontSize)
        env.player.addListener { [weak self] event in
            if event == .trackChanged || event == .stateChanged { self?.load() }
        }
    }

    private var item: PlaylistItem? { env.player.isActive ? env.player.currentItem : nil }

    func load(refetch: Bool = false) {
        guard isActive else { return }
        guard let item else {
            loadedItem = nil
            set(.nothingPlaying, text: "")
            return
        }
        guard refetch || item.id != loadedItem else { return }
        loadedItem = item.id
        isEditing = false
        heading = [item.track.displayTitle, item.track.artist].filter { !$0.isEmpty }.joined(separator: " – ")
        if item.isStream {
            set(.stream, text: "")
            return
        }
        set(.loading, text: "")
        task?.cancel()
        let service = env.lyrics
        let track = item.track
        let id = item.id
        task = Task {
            do {
                let result = try await service.lyrics(for: track, refetch: refetch)
                guard !Task.isCancelled, id == loadedItem else { return }
                if let result {
                    source = result.source
                    set(result.instrumental ? .instrumental : .loaded, text: result.text)
                } else {
                    set(.notFound, text: "")
                }
            } catch {
                guard !Task.isCancelled, id == loadedItem else { return }
                set(.failed(error.localizedDescription), text: "")
            }
        }
    }

    private func set(_ status: Status, text: String) {
        self.status = status
        self.text = text
        synced = LRCParser.looksSynced(text)
        lines = synced ? LRCParser.parse(text) : []
    }

    var canEdit: Bool { item?.track.id != nil && item?.isStream == false }

    func beginEditing() {
        draft = text
        isEditing = true
    }

    func save() {
        guard let trackId = item?.track.id else { return }
        let draft = self.draft
        let service = env.lyrics
        Task {
            try? await service.save(draft, trackId: trackId)
            isEditing = false
            loadedItem = nil
            load()
        }
    }

    /// Removes the user's own lyrics (falls back to tag / LRCLIB).
    func clear() {
        draft = ""
        save()
    }
}

struct LyricsApplet: View {
    @Bindable var model: LyricsAppletModel
    let player: PlayerController

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(model.heading).font(.callout.weight(.medium)).lineLimit(1)
            if model.status == .loaded {
                Text(sourceLabel).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
            Spacer()
            if model.isEditing {
                Button("Cancel") { model.isEditing = false }
                Button("Save") { model.save() }.keyboardShortcut(.defaultAction)
            } else {
                Button { model.load(refetch: true) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload lyrics from LRCLIB")
                    .disabled(!model.canEdit)
                Button { model.beginEditing() } label: { Image(systemName: "pencil") }
                    .help("Edit lyrics")
                    .disabled(!model.canEdit)
                if model.source == "user" && model.status == .loaded {
                    Button { model.clear() } label: { Image(systemName: "trash") }.help("Remove your lyrics")
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private var sourceLabel: String {
        switch model.source {
        case "user": "Edited"
        case "tag": "From file"
        default: "LRCLIB"
        }
    }

    @ViewBuilder private var content: some View {
        if model.isEditing {
            TextEditor(text: $model.draft)
                .font(.system(size: model.fontSize))
                .padding(6)
        } else {
            switch model.status {
            case .nothingPlaying: message("Lyrics appear here while a track plays.")
            case .loading: ProgressView().controlSize(.small)
            case .notFound: message("No lyrics found.", detail: "Use the pencil to add them yourself.")
            case .instrumental: message("Instrumental")
            case .stream: message("Lyrics are not available for streams.")
            case .failed(let error): message("Lyrics could not be loaded.", detail: error)
            case .loaded:
                if model.synced {
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        SyncedLyricsView(lines: model.lines, current: LRCParser.currentLine(model.lines, at: player.currentTime),
                                         fontSize: model.fontSize)
                    }
                } else {
                    ScrollView {
                        Text(model.text)
                            .font(.system(size: model.fontSize))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                    }
                }
            }
        }
    }

    private func message(_ text: String, detail: String? = nil) -> some View {
        VStack(spacing: 4) {
            Text(text).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

/// Synced lyrics: the current line is highlighted and kept in the middle.
struct SyncedLyricsView: View {
    let lines: [LyricsLine]
    let current: Int?
    let fontSize: Double

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: index == current ? fontSize + 2 : fontSize, weight: index == current ? .bold : .regular))
                            .foregroundStyle(index == current ? Color.primary : Color.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .id(index)
                    }
                }
                .padding(.vertical, 120)
                .padding(.horizontal, 14)
            }
            .onChange(of: current) { _, new in
                guard let new else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
    }
}

struct LyricsSettingsView: View {
    @Bindable var model: LyricsAppletModel

    var body: some View {
        Form {
            Slider(value: $model.fontSize, in: 10...24, step: 1) { Text("Font size") }
            Text("Lyrics come from text you saved, the file’s lyrics tag, then LRCLIB (lrclib.net).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 280)
    }
}
