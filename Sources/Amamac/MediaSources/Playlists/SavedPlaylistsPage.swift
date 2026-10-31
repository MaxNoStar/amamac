import AmamacBase
import AmamacDatabase
import AmamacDynamic
import AmamacModels
import AmamacPlaylist
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class SavedPlaylistsModel {
    struct FileEntry: Identifiable, Hashable {
        var url: URL
        var id: URL { url }
    }

    let env: AppEnvironment
    let store: SavedPlaylistStore
    private(set) var saved: [SavedPlaylistStore.Summary] = []
    private(set) var files: [FileEntry] = []
    var selection: Set<String> = []
    var renaming: Int64?
    var renameText = ""

    init(env: AppEnvironment) {
        self.env = env
        store = env.savedPlaylists
        NotificationCenter.default.addObserver(forName: SavedPlaylistStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        scanFiles()
    }

    func reload() { saved = store.all() }

    /// Playlist files inside the collection folders.
    func scanFiles() {
        let roots = env.collectionFolders.map(\.path)
        Task {
            let found = await Task.detached { () -> [URL] in
                var urls: [URL] = []
                for root in roots {
                    let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                    while let url = e?.nextObject() as? URL {
                        if PlaylistFileFormat.from(url: url) != nil { urls.append(url) }
                        if urls.count > 500 { break }
                    }
                }
                return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }.value
            files = found.map(FileEntry.init(url:))
        }
    }

    func load(_ id: Int64, mode: LibraryActions.AddMode) {
        Task { env.actions.add(await store.items(playlistId: id), mode: mode) }
    }

    func load(file: URL, mode: LibraryActions.AddMode) { env.actions.addURLs([file], mode: mode) }

    func saveCurrent() {
        NSApp.sendAction(#selector(PlaylistCommands.savePlaylist(_:)), to: nil, from: nil)
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PlaylistFileFormat.contentTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls { _ = try? await store.importFile(url) }
            env.status.showMessage("Imported \(urls.count) playlist\(urls.count == 1 ? "" : "s").")
        }
    }

    func importIntoDatabase(_ url: URL) {
        Task { _ = try? await store.importFile(url) }
    }

    func export(_ summary: SavedPlaylistStore.Summary) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = summary.name + ".m3u8"
        panel.allowedContentTypes = PlaylistFileFormat.contentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await store.export(playlistId: summary.id, to: url)
            } catch {
                env.status.showMessage("Could not export: \(error.localizedDescription)")
            }
        }
    }

    func delete(_ summary: SavedPlaylistStore.Summary) {
        guard Confirm.ask("Delete the playlist “\(summary.name)”?", info: "The tracks themselves are not affected.",
                          action: "Delete") else { return }
        store.delete(ids: [summary.id])
    }

    func commitRename() {
        if let id = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty { store.rename(id: id, to: renameText) }
        renaming = nil
    }
}

struct SavedPlaylistsView: View {
    @Bindable var model: SavedPlaylistsModel

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Saved in Amamac") {
                    if model.saved.isEmpty {
                        Text("Use Save in the playlist’s bottom bar to keep a playlist here.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.saved) { p in savedRow(p) }
                }
                Section("Files in the Collection") {
                    if model.files.isEmpty {
                        Text("No playlist files were found in the collection folders.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.files) { f in fileRow(f.url) }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button { model.saveCurrent() } label: { Label("Save Current", systemImage: "square.and.arrow.down") }
                Button { model.importFile() } label: { Label("Import…", systemImage: "square.and.arrow.down.on.square") }
                Spacer()
                Button { model.scanFiles() } label: { Image(systemName: "arrow.clockwise") }.help("Look for playlist files again")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func savedRow(_ p: SavedPlaylistStore.Summary) -> some View {
        HStack {
            Image(systemName: "music.note.list").foregroundStyle(.secondary)
            if model.renaming == p.id {
                TextField("Name", text: $model.renameText).onSubmit { model.commitRename() }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).lineLimit(1)
                    Text("\(p.trackCount) tracks · \(TimeFormatting.durationMs(p.durationMs))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.load(p.id, mode: .append) }
        .onDrag {
            let provider = NSItemProvider()
            provider.suggestedName = p.name
            return provider
        }
        .contextMenu {
            Button("Replace Playlist") { model.load(p.id, mode: .replace) }
            Button("Add to Playlist") { model.load(p.id, mode: .append) }
            Button("Queue Tracks") { model.load(p.id, mode: .queue) }
            Divider()
            Button("Rename") { model.renameText = p.name; model.renaming = p.id }
            Button("Export As…") { model.export(p) }
            Button("Delete…") { model.delete(p) }
        }
    }

    private func fileRow(_ url: URL) -> some View {
        HStack {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.load(file: url, mode: .append) }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .contextMenu {
            Button("Replace Playlist") { model.load(file: url, mode: .replace) }
            Button("Add to Playlist") { model.load(file: url, mode: .append) }
            Divider()
            Button("Copy to Saved Playlists") { model.importIntoDatabase(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
