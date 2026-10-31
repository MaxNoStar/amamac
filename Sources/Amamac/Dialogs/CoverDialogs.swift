import AppKit
import SwiftUI
import AmamacCore

/// Searches Cover Art Archive and iTunes for an album and lets the user pick a cover.
struct CoverFetchView: View {
    let album: AlbumReference
    let fetcher: CoverFetcher
    let onChoose: (Data) -> Void
    let onCancel: () -> Void
    @State private var candidates: [CoverFetcher.Candidate]?
    @State private var images: [URL: NSImage] = [:]
    @State private var selected: URL?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Covers for “\(album.album)”").font(.headline)
            Text(album.artist).foregroundStyle(.secondary)
            Group {
                if let candidates {
                    if candidates.isEmpty {
                        Text("No covers were found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                                ForEach(candidates) { c in tile(c) }
                            }
                            .padding(4)
                        }
                    }
                } else {
                    ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 260)
            HStack {
                Text("Sources: Cover Art Archive (MusicBrainz) and the iTunes Search API.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Use Cover") { choose() }.keyboardShortcut(.defaultAction).disabled(selected == nil || saving)
            }
        }
        .padding(16)
        .frame(width: 560, height: 460)
        .task {
            let found = await fetcher.candidates(album: album.album, artist: album.artist, releaseId: album.releaseId)
            candidates = found
            selected = found.first?.imageURL
            for c in found {
                if let data = try? await fetcher.imageData(c), let image = NSImage(data: data) { images[c.imageURL] = image }
            }
        }
    }

    private func tile(_ c: CoverFetcher.Candidate) -> some View {
        VStack(spacing: 4) {
            CoverImage(image: images[c.imageURL]).frame(width: 140, height: 140)
            Text(c.title).font(.caption.weight(.medium)).lineLimit(1)
            Text(c.source.rawValue + (images[c.imageURL].map { " · \(Int($0.size.width))×\(Int($0.size.height))" } ?? ""))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).stroke(selected == c.imageURL ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { selected = c.imageURL }
        .onTapGesture(count: 2) { selected = c.imageURL; choose() }
    }

    private func choose() {
        guard let selected, let candidate = candidates?.first(where: { $0.imageURL == selected }) else { return }
        saving = true
        Task {
            if let data = try? await fetcher.imageData(candidate) { onChoose(data) } else { saving = false }
        }
    }
}

/// Cover-related actions shared by the collection, Cover Manager and menus.
@MainActor
enum CoverActions {
    private static var windows: [NSWindow] = []

    static func fetch(_ album: AlbumReference, env: AppEnvironment) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let close: () -> Void = { [weak window] in window?.close() }
        let view = CoverFetchView(album: album, fetcher: CoverFetcher(http: env.http), onChoose: { data in
            Task {
                do {
                    try await env.covers.setCover(albumKey: album.albumKey, imageData: data, source: .fetched)
                    changed(album.albumKey, env: env)
                } catch {
                    env.status.showMessage("Could not save the cover: \(error.localizedDescription)")
                }
                close()
            }
        }, onCancel: close)
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Fetch Cover"
        window.isReleasedWhenClosed = false
        window.center()
        retain(window)
        window.makeKeyAndOrderFront(nil)
    }

    /// Fetches the best candidate without asking (Cover Manager "Fetch Missing Covers").
    static func fetchAutomatically(_ album: AlbumReference, env: AppEnvironment) async -> Bool {
        let fetcher = CoverFetcher(http: env.http)
        let candidates = await fetcher.candidates(album: album.album, artist: album.artist, releaseId: album.releaseId)
        for candidate in candidates.prefix(2) {
            if let data = try? await fetcher.imageData(candidate), NSImage(data: data) != nil {
                try? await env.covers.setCover(albumKey: album.albumKey, imageData: data, source: .fetched)
                changed(album.albumKey, env: env)
                return true
            }
        }
        return false
    }

    static func setCustom(_ album: AlbumReference, env: AppEnvironment) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a cover for “\(album.album)”"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        Task {
            do {
                try await env.covers.setCover(albumKey: album.albumKey, imageData: data)
                changed(album.albumKey, env: env)
            } catch {
                env.status.showMessage("Could not set the cover: \(error.localizedDescription)")
            }
        }
    }

    static func unset(_ album: AlbumReference, env: AppEnvironment) {
        Task {
            try? await env.covers.unsetCover(albumKey: album.albumKey)
            changed(album.albumKey, env: env)
        }
    }

    static func display(_ album: AlbumReference, env: AppEnvironment) {
        Task {
            guard let data = await env.covers.originalImageData(albumKey: album.albumKey), let image = NSImage(data: data) else {
                env.status.showMessage("“\(album.album)” has no cover.")
                return
            }
            CoverViewerWindow.show(image: image, title: [album.album, album.artist].filter { !$0.isEmpty }.joined(separator: " – "))
        }
    }

    static func changed(_ albumKey: String, env: AppEnvironment) {
        env.coverImages.invalidate(albumKey: albumKey)
        NotificationCenter.default.post(name: AppEnvironment.coverChanged, object: albumKey)
    }

    static func retain(_ window: NSWindow) {
        windows.append(window)
        let id = ObjectIdentifier(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeAll { ObjectIdentifier($0) == id } }
        }
    }
}

// MARK: - Cover Manager

@MainActor
@Observable
final class CoverManagerModel {
    enum Filter: String, CaseIterable { case all = "All Albums", withCover = "With Cover", withoutCover = "Without Cover" }

    struct Album: Identifiable {
        var group: CollectionGroup
        var reference: AlbumReference
        var hasCover: Bool?
        var id: String { reference.albumKey }
    }

    let env: AppEnvironment
    private(set) var albums: [Album] = []
    var filter = Filter.all
    var search = ""
    private(set) var fetching = false
    private(set) var progress = ""
    @ObservationIgnored private var cancelFetch = false

    init(env: AppEnvironment) {
        self.env = env
        NotificationCenter.default.addObserver(forName: AppEnvironment.coverChanged, object: nil, queue: .main) { [weak self] note in
            let key = note.object as? String
            MainActor.assumeIsolated { self?.coverChanged(key) }
        }
        reload()
    }

    func reload() {
        let db = env.database
        Task {
            let groups = (try? await db.writer.read { try CollectionQueries.allAlbums($0) }) ?? []
            albums = groups.compactMap { g in
                guard let key = g.albumKey else { return nil }
                return Album(group: g, reference: AlbumReference(albumKey: key, album: g.name, artist: g.albumArtist ?? "", releaseId: nil), hasCover: nil)
            }
            for i in albums.indices {
                let has = await env.covers.cover(albumKey: albums[i].id, size: 128) != nil
                if i < albums.count { albums[i].hasCover = has }
            }
        }
    }

    private func coverChanged(_ key: String?) {
        guard let key, let i = albums.firstIndex(where: { $0.id == key }) else { return }
        Task { albums[i].hasCover = await env.covers.cover(albumKey: key, size: 128) != nil }
    }

    var shown: [Album] {
        let needle = TextFolding.fold(search)
        return albums.filter { album in
            switch filter {
            case .all: break
            case .withCover: if album.hasCover != true { return false }
            case .withoutCover: if album.hasCover != false { return false }
            }
            return needle.isEmpty || TextFolding.fold(album.group.name + " " + (album.group.albumArtist ?? "")).contains(needle)
        }
    }

    var missingCount: Int { albums.filter { $0.hasCover == false }.count }

    func fetchMissing() {
        guard !fetching else {
            cancelFetch = true
            return
        }
        fetching = true
        cancelFetch = false
        let missing = albums.filter { $0.hasCover == false }
        Task {
            var found = 0
            for (n, album) in missing.enumerated() {
                if cancelFetch { break }
                progress = "Fetching \(n + 1) of \(missing.count): \(album.group.displayName)"
                if await CoverActions.fetchAutomatically(album.reference, env: env) { found += 1 }
            }
            progress = "Found \(found) of \(missing.count) missing covers."
            fetching = false
        }
    }
}

struct CoverManagerView: View {
    @Bindable var model: CoverManagerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $model.filter) {
                    ForEach(CoverManagerModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search albums", text: $model.search).textFieldStyle(.roundedBorder)
                Button(model.fetching ? "Stop" : "Fetch Missing Covers") { model.fetchMissing() }
                    .disabled(!model.fetching && model.missingCount == 0)
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                    ForEach(model.shown) { album in
                        CoverManagerTile(album: album, env: model.env)
                    }
                }
                .padding(14)
            }
            Divider()
            HStack {
                Text("\(model.albums.count) albums, \(model.missingCount) without cover").font(.caption)
                Spacer()
                Text(model.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

struct CoverManagerTile: View {
    let album: CoverManagerModel.Album
    let env: AppEnvironment

    var body: some View {
        VStack(spacing: 4) {
            AlbumCover(albumKey: album.id, covers: env.coverImages)
                .id(album.hasCover)
                .frame(width: 120, height: 120)
            Text(album.group.displayName).font(.caption.weight(.medium)).lineLimit(1)
            Text(album.group.albumArtist ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 130)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { CoverActions.display(album.reference, env: env) }
        .contextMenu {
            Button("Fetch Cover…") { CoverActions.fetch(album.reference, env: env) }
            Button("Display Cover") { CoverActions.display(album.reference, env: env) }
            Button("Set Custom Cover…") { CoverActions.setCustom(album.reference, env: env) }
            Button("Unset Cover") { CoverActions.unset(album.reference, env: env) }
        }
    }
}

@MainActor
enum CoverManagerWindow {
    private static var window: NSWindow?

    static func show(env: AppEnvironment) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: CoverManagerView(model: CoverManagerModel(env: env))))
        w.title = "Cover Manager"
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 820, height: 600))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { window = nil }
        }
        w.makeKeyAndOrderFront(nil)
    }
}
