import AmamacBase
import AmamacDatabase
import AmamacModels
import AmamacPlaylist
import AppKit
import SwiftUI

// MARK: - Edit Queue

@MainActor
@Observable
final class QueueEditorModel {
    struct Row: Identifiable, Hashable {
        var id: PlaylistItemID
        var title: String
        var detail: String
        var duration: TimeInterval
    }

    let env: AppEnvironment
    private(set) var rows: [Row] = []
    var selection: Set<PlaylistItemID> = []
    @ObservationIgnored private var observation: PlaylistObservation?

    init(env: AppEnvironment) {
        self.env = env
        observation = env.playlist.observe { [weak self] change in
            switch change {
            case .queueChanged, .removed, .reloaded, .updated: self?.reload()
            default: break
            }
        }
        reload()
    }

    func reload() {
        let model = env.playlist
        rows = model.queue.compactMap { id in
            guard let item = model.item(id) else { return nil }
            let detail = [item.track.artist, item.track.album].filter { !$0.isEmpty }.joined(separator: " – ")
            return Row(id: id, title: item.streamTitle ?? item.track.displayTitle, detail: detail, duration: item.duration)
        }
        selection = selection.filter { id in rows.contains { $0.id == id } }
    }

    var totalDuration: TimeInterval { rows.reduce(0) { $0 + $1.duration } }

    func move(from source: IndexSet, to destination: Int) {
        var ids = rows.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        env.playlist.setQueue(ids)
    }

    /// Moves the selection one step up (-1) or down (+1).
    func shift(_ delta: Int) {
        var ids = rows.map(\.id)
        let picked = ids.indices.filter { selection.contains(ids[$0]) }
        guard !picked.isEmpty else { return }
        let ordered = delta < 0 ? picked : picked.reversed()
        for i in ordered {
            let j = i + delta
            guard ids.indices.contains(j), !selection.contains(ids[j]) else { continue }
            ids.swapAt(i, j)
        }
        env.playlist.setQueue(ids)
    }

    func dequeueSelection() { env.playlist.dequeue(selection) }
    func clear() { env.playlist.setQueue([]) }
}

struct QueueEditorView: View {
    @Bindable var model: QueueEditorModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Circle().fill(Color.green))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).lineLimit(1)
                            if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        Text(TimeFormatting.duration(row.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .tag(row.id)
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .overlay {
                if model.rows.isEmpty {
                    Text("The queue is empty. Queue tracks from the playlist with ⌘D.").foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button { model.shift(-1) } label: { Image(systemName: "arrow.up") }.help("Move Up").disabled(model.selection.isEmpty)
                Button { model.shift(1) } label: { Image(systemName: "arrow.down") }.help("Move Down").disabled(model.selection.isEmpty)
                Button("Dequeue") { model.dequeueSelection() }.disabled(model.selection.isEmpty)
                Button("Clear Queue") { model.clear() }.disabled(model.rows.isEmpty)
                Spacer()
                Text("\(model.rows.count) tracks (\(TimeFormatting.duration(model.totalDuration)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

enum QueueEditorWindow {
    static func show(env: AppEnvironment) {
        SingleWindow.show("QueueEditorWindow") {
            let w = NSWindow(contentViewController: NSHostingController(rootView: QueueEditorView(model: QueueEditorModel(env: env))))
            w.title = "Queue Editor"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 480, height: 420))
            return w
        }
    }
}

// MARK: - Bookmark Manager

@MainActor
@Observable
final class BookmarkManagerModel {
    let env: AppEnvironment
    let store: BookmarkStore
    private(set) var bookmarks: [BookmarkRecord] = []
    /// Bookmark ids (always set for stored records).
    var selection: Set<Int64?> = []
    var renaming: Int64?
    var renameText = ""

    init(env: AppEnvironment) {
        self.env = env
        store = env.bookmarks
        NotificationCenter.default.addObserver(forName: BookmarkStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func reload() { bookmarks = store.all() }

    var selected: [BookmarkRecord] { bookmarks.filter { selection.contains($0.id) } }

    func goTo(_ bookmark: BookmarkRecord) {
        guard let url = URL(string: bookmark.url) else { return }
        LinkHandler.open(url, env: env)
    }

    func beginRename(_ bookmark: BookmarkRecord) {
        renaming = bookmark.id
        renameText = bookmark.name
    }

    func commitRename() {
        if let id = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty { store.rename(id: id, to: renameText) }
        renaming = nil
    }

    func deleteSelection() { store.delete(ids: selected.compactMap(\.id)) }

    static func kindName(_ kind: BookmarkRecord.Kind) -> String {
        switch kind {
        case .position: "Track Position"
        case .view: "Media Sources View"
        case .playlist: "Playlist"
        }
    }
}

struct BookmarkManagerView: View {
    @Bindable var model: BookmarkManagerModel

    var body: some View {
        VStack(spacing: 0) {
            Table(model.bookmarks, selection: $model.selection) {
                TableColumn("Name") { b in
                    if model.renaming == b.id {
                        TextField("Name", text: $model.renameText).onSubmit { model.commitRename() }
                    } else {
                        Label(b.name, systemImage: b.kind == .position ? "bookmark" : b.kind == .view ? "rectangle.stack" : "music.note.list")
                    }
                }
                .width(min: 160, ideal: 260)
                TableColumn("Type") { b in Text(BookmarkManagerModel.kindName(b.kind)).foregroundStyle(.secondary) }
                    .width(min: 90, ideal: 130)
                TableColumn("Link") { b in Text(b.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            .contextMenu(forSelectionType: Int64?.self) { ids in
                if let first = model.bookmarks.first(where: { ids.contains($0.id) }) {
                    Button("Go To") { model.goTo(first) }
                    Button("Rename") { model.beginRename(first) }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(first.url, forType: .string)
                    }
                    Divider()
                    Button("Delete") {
                        model.selection = ids
                        model.deleteSelection()
                    }
                }
            } primaryAction: { ids in
                if let first = model.bookmarks.first(where: { ids.contains($0.id) }) { model.goTo(first) }
            }
            .overlay {
                if model.bookmarks.isEmpty {
                    Text("No bookmarks yet. Add position markers from the toolbar, or use “Bookmark This View” in Media Sources.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            Divider()
            HStack {
                Button("Go To") { model.selected.first.map(model.goTo) }.disabled(model.selected.count != 1)
                Button("Rename") { model.selected.first.map(model.beginRename) }.disabled(model.selected.count != 1)
                Button("Delete") { model.deleteSelection() }.disabled(model.selected.isEmpty)
                Spacer()
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 320)
    }
}

enum BookmarkManagerWindow {
    static func show(env: AppEnvironment) {
        SingleWindow.show("BookmarkManagerWindow") {
            let w = NSWindow(contentViewController: NSHostingController(rootView: BookmarkManagerView(model: BookmarkManagerModel(env: env))))
            w.title = "Bookmark Manager"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 640, height: 400))
            return w
        }
    }
}

// MARK: - amamac:// links

@MainActor
enum LinkHandler {
    static func open(_ url: URL, env: AppEnvironment) {
        guard let link = AmamacLink(url: url) else {
            env.status.showMessage("Amamac does not understand the link \(url.absoluteString).")
            return
        }
        open(link, env: env)
    }

    static func open(_ link: AmamacLink, env: AppEnvironment) {
        guard let router = env.router else { return }
        switch link {
        case .position(let trackId, let seconds):
            if let item = env.playlist.items.first(where: { $0.source == .collection && $0.track.id == trackId }) {
                if env.player.currentItem?.id == item.id, env.player.isActive {
                    env.player.seek(to: seconds)
                } else {
                    env.player.play(item.id, startAt: seconds)
                }
            } else if let track = (try? env.database.tracks(ids: [trackId]))?.first {
                if let id = env.playlist.append([track.playlistItem()]).first { env.player.play(id, startAt: seconds) }
            } else {
                env.status.showMessage("The bookmarked track is no longer in the collection.")
            }
        case .collection(let filter, let levels):
            let parsed = levels.compactMap(CollectionLevel.init(rawValue:))
            if !parsed.isEmpty { env.settings.collectionGrouping = CollectionGrouping(parsed) }
            router.showInCollection(filter: filter)
        case .category(let name, let path):
            guard let category = MediaCategory(rawValue: name) else {
                env.status.showMessage("Unknown Media Sources category “\(name)”.")
                return
            }
            let page = router.showMediaSources(category)
            guard let path, let files = page as? FileBrowserPage else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                env.status.showMessage("The folder “\(path)” does not exist.")
                return
            }
            // A link shows the folder once; it doesn't become where Files opens next time.
            let startFolder = env.settings.string(AppSettings.Key.fileBrowserFolder)
            files.model.go(to: URL(fileURLWithPath: path))
            env.settings.set(startFolder, AppSettings.Key.fileBrowserFolder)
        }
    }
}
