import AmamacBase
import AmamacDatabase
import AmamacDynamic
import AmamacModels
import AmamacPlaylist
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Media Sources › Playlists: Saved Playlists, Dynamic Playlists, Automated Playlist Generator.
final class PlaylistsBrowserPage: NSViewController, MediaSourcePage {
    let env: AppEnvironment
    weak var owner: MediaSourcesViewController?

    enum Section: String, CaseIterable {
        case saved, dynamic, generator
        var title: String {
            switch self {
            case .saved: "Saved Playlists"
            case .dynamic: "Dynamic Playlists"
            case .generator: "Automated Playlist Generator"
            }
        }
        var summary: String {
            switch self {
            case .saved: "Playlists stored in Amamac and playlist files in your collection"
            case .dynamic: "Playlists that keep refilling themselves by rules"
            case .generator: "Builds a playlist that meets constraints such as length and tags"
            }
        }
        var symbol: String {
            switch self {
            case .saved: "music.note.list"
            case .dynamic: "dice"
            case .generator: "wand.and.stars"
            }
        }
    }

    init(env: AppEnvironment, owner: MediaSourcesViewController) {
        self.env = env
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var crumbTitle: String { MediaCategory.playlists.title }
    var crumbSymbol: String { MediaCategory.playlists.symbol }

    override func loadView() {
        let host = NSHostingView(rootView: SubcategoryList(items: Section.allCases.map { ($0.title, $0.summary, $0.symbol) }) { [weak self] i in
            self?.open(Section.allCases[i])
        })
        host.sizingOptions = []
        view = host
    }

    @discardableResult
    func open(_ section: Section) -> NSViewController {
        let page: NSViewController
        switch section {
        case .saved: page = HostedPage(title: section.title, symbol: section.symbol, root: SavedPlaylistsView(model: SavedPlaylistsModel(env: env)))
        case .dynamic: page = HostedPage(title: section.title, symbol: section.symbol, root: DynamicPlaylistsView(model: DynamicPlaylistsModel(env: env)))
        case .generator: page = HostedPage(title: section.title, symbol: section.symbol, root: GeneratorView(model: GeneratorModel(env: env)))
        }
        owner?.push(page)
        return page
    }
}

/// A Media Sources page hosting a SwiftUI view.
final class HostedPage<Root: View>: NSViewController, MediaSourcePage {
    let crumbTitle: String
    let crumbSymbol: String
    let root: Root

    init(title: String, symbol: String, root: Root) {
        crumbTitle = title
        crumbSymbol = symbol
        self.root = root
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        view = host
    }
}

struct SubcategoryList: View {
    let items: [(String, String, String)]
    let onOpen: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    Button { onOpen(i) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: items[i].2).font(.system(size: 22)).frame(width: 34).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(items[i].0).font(.headline)
                                Text(items[i].1).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Saved playlists

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
        store = SavedPlaylistStore(database: env.database)
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

    func load(_ id: Int64, mode: Commands.AddMode) {
        Task { Commands.add(await store.items(playlistId: id), mode: mode) }
    }

    func load(file: URL, mode: Commands.AddMode) { Commands.addURLs([file], mode: mode) }

    func saveCurrent() {
        AppDelegate.shared?.savePlaylist(nil)
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PlaylistFileFormat.allCases.compactMap { UTType(filenameExtension: $0.rawValue) }
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
        panel.allowedContentTypes = PlaylistFileFormat.allCases.compactMap { UTType(filenameExtension: $0.rawValue) }
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
        let alert = NSAlert()
        alert.messageText = "Delete the playlist “\(summary.name)”?"
        alert.informativeText = "The tracks themselves are not affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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

// MARK: - Dynamic playlists

@MainActor
@Observable
final class DynamicPlaylistsModel {
    let env: AppEnvironment
    let store: GeneratorStore
    private(set) var playlists: [DynamicPlaylist] = []
    var selectedId: Int64?
    var editing: DynamicPlaylist?

    init(env: AppEnvironment) {
        self.env = env
        store = GeneratorStore(database: env.database)
        playlists = store.dynamicPlaylists()
        selectedId = env.dynamicMode.active?.id ?? playlists.first?.id
    }

    var mode: DynamicModeController { env.dynamicMode }
    var selected: DynamicPlaylist? { playlists.first { $0.id == selectedId } }

    func toggleOn() {
        if mode.active != nil {
            mode.stop()
        } else if let selected {
            mode.start(selected)
        }
    }

    func newPlaylist() {
        editing = DynamicPlaylist(name: "New Dynamic Playlist", bias: .random)
    }

    func duplicate() {
        guard var copy = selected else { return }
        copy.id = nil
        copy.name += " (copy)"
        editing = copy
    }

    func save(_ playlist: DynamicPlaylist) {
        let saved = store.save(playlist)
        playlists = store.dynamicPlaylists()
        selectedId = saved.id
        mode.definitionChanged(saved)
        editing = nil
    }

    func delete() {
        guard let selected, let id = selected.id else { return }
        if mode.active?.id == id { mode.stop() }
        store.deleteDynamicPlaylist(id: id)
        playlists = store.dynamicPlaylists()
        selectedId = playlists.first?.id
    }
}

struct DynamicPlaylistsView: View {
    @Bindable var model: DynamicPlaylistsModel

    var body: some View {
        let mode = model.mode
        VStack(spacing: 0) {
            List(selection: $model.selectedId) {
                ForEach(model.playlists) { p in
                    HStack {
                        Image(systemName: mode.active?.id == p.id ? "dice.fill" : "dice")
                            .foregroundStyle(mode.active?.id == p.id ? Color.amamacAccent : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            Text(p.bias.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(p.id)
                    .onTapGesture(count: 2) {
                        model.selectedId = p.id
                        mode.start(p)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Dynamic Mode", isOn: Binding(get: { mode.active != nil }, set: { _ in model.toggleOn() }))
                        .toggleStyle(.switch)
                        .disabled(model.selected == nil && mode.active == nil)
                    Spacer()
                    if mode.isWorking { ProgressView().controlSize(.small) }
                    Button("Repopulate") { mode.repopulate() }.disabled(mode.active == nil)
                }
                Stepper("Previous tracks: \(mode.previousCount)", value: Binding(get: { mode.previousCount }, set: { mode.previousCount = $0 }), in: 0...50)
                Stepper("Upcoming tracks: \(mode.upcomingCount)", value: Binding(get: { mode.upcomingCount }, set: { mode.upcomingCount = $0 }), in: 1...100)
                Toggle("Allow duplicates", isOn: Binding(get: { mode.allowDuplicates }, set: { mode.allowDuplicates = $0 }))
                HStack {
                    Button { model.newPlaylist() } label: { Image(systemName: "plus") }.help("New dynamic playlist")
                    Button { model.duplicate() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate").disabled(model.selected == nil)
                    Button("Edit…") { model.editing = model.selected }.disabled(model.selected == nil)
                    Spacer()
                    Button { model.delete() } label: { Image(systemName: "trash") }.help("Delete").disabled(model.selected == nil)
                }
                .buttonStyle(.borderless)
            }
            .padding(10)
        }
        .sheet(item: $model.editing) { playlist in
            DynamicPlaylistEditor(playlist: playlist, onSave: { model.save($0) }, onCancel: { model.editing = nil })
        }
    }
}

struct DynamicPlaylistEditor: View {
    @State var playlist: DynamicPlaylist
    let onSave: (DynamicPlaylist) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $playlist.name).font(.headline)
            ScrollView {
                BiasEditor(bias: $playlist.bias, onRemove: nil).padding(4)
            }
            .frame(minHeight: 260)
            Text("Searches use the collection filter syntax, e.g. genre:jazz year:<1970 rating:>3.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(playlist) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 440)
    }
}

/// Recursive editor for a bias tree.
struct BiasEditor: View {
    @Binding var bias: Bias
    let onRemove: (() -> Void)?

    enum Kind: String, CaseIterable, Identifiable {
        case random = "Random", and = "Match All", or = "Match Any", not = "Not", partition = "Partition", ifElse = "If / Else"
        case search = "Search", albumPlay = "Album Play", quizPlay = "Quiz Play"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch bias {
        case .random: .random
        case .and: .and
        case .or: .or
        case .not: .not
        case .partition: .partition
        case .ifElse: .ifElse
        case .search: .search
        case .albumPlay: .albumPlay
        case .quizPlay: .quizPlay
        }
    }

    private func make(_ kind: Kind) -> Bias {
        let children = bias.children.isEmpty ? [Bias.search("")] : bias.children
        switch kind {
        case .random: return .random
        case .and: return .and(children)
        case .or: return .or(children)
        case .not: return .not(children[0])
        case .partition: return .partition(children.map { .init(weight: 1, bias: $0) })
        case .ifElse: return .ifElse(children)
        case .search: return .search("")
        case .albumPlay: return .albumPlay(.directlyFollows)
        case .quizPlay: return .quizPlay(.artist)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: Binding(get: { kind }, set: { bias = make($0) })) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                detail
                Spacer(minLength: 0)
                if let onRemove {
                    Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            if !bias.children.isEmpty || [.and, .or, .partition, .ifElse].contains(kind) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bias.children.indices, id: \.self) { i in
                        HStack(alignment: .top) {
                            if case .partition(let parts) = bias {
                                TextField("Weight", value: Binding(get: { parts[i].weight }, set: { w in
                                    var p = parts
                                    p[i].weight = max(0, w)
                                    bias = .partition(p)
                                }), format: .number).frame(width: 44)
                            }
                            AnyView(BiasEditor(bias: child(i), onRemove: canRemoveChildren ? { removeChild(i) } : nil))
                        }
                    }
                    if kind != .not {
                        Button { addChild() } label: { Label("Add", systemImage: "plus.circle") }.buttonStyle(.borderless).font(.caption)
                    }
                }
                .padding(.leading, 18)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch bias {
        case .search(let q):
            TextField("Filter, e.g. genre:rock", text: Binding(get: { q }, set: { bias = .search($0) }))
        case .albumPlay(let mode):
            Picker("", selection: Binding(get: { mode }, set: { bias = .albumPlay($0) })) {
                ForEach(Bias.AlbumPlayMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
        case .quizPlay(let field):
            Picker("Letter chain on", selection: Binding(get: { field }, set: { bias = .quizPlay($0) })) {
                ForEach(Bias.QuizField.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .fixedSize()
        default:
            EmptyView()
        }
    }

    private var canRemoveChildren: Bool { kind != .not && bias.children.count > 1 }

    private func child(_ i: Int) -> Binding<Bias> {
        Binding(get: { bias.children.indices.contains(i) ? bias.children[i] : .random }, set: { new in
            switch bias {
            case .and(var c): c[i] = new; bias = .and(c)
            case .or(var c): c[i] = new; bias = .or(c)
            case .ifElse(var c): c[i] = new; bias = .ifElse(c)
            case .not: bias = .not(new)
            case .partition(var p): p[i].bias = new; bias = .partition(p)
            default: break
            }
        })
    }

    private func addChild() {
        switch bias {
        case .and(let c): bias = .and(c + [.search("")])
        case .or(let c): bias = .or(c + [.search("")])
        case .ifElse(let c): bias = .ifElse(c + [.random])
        case .partition(let p): bias = .partition(p + [.init(weight: 1, bias: .random)])
        default: break
        }
    }

    private func removeChild(_ i: Int) {
        switch bias {
        case .and(var c): c.remove(at: i); bias = .and(c)
        case .or(var c): c.remove(at: i); bias = .or(c)
        case .ifElse(var c): c.remove(at: i); bias = .ifElse(c)
        case .partition(var p): p.remove(at: i); bias = .partition(p)
        default: break
        }
    }
}

// MARK: - Automated Playlist Generator

@MainActor
@Observable
final class GeneratorModel {
    let env: AppEnvironment
    let store: GeneratorStore
    private(set) var presets: [GeneratorPreset] = []
    var selectedId: Int64?
    var draft: GeneratorPreset?
    var quality = 2.0
    private(set) var running = false
    private(set) var result: (ids: [Int64], quality: Double, duration: Int)?

    init(env: AppEnvironment) {
        self.env = env
        store = GeneratorStore(database: env.database)
        presets = store.generatorPresets()
        select(presets.first?.id)
    }

    func select(_ id: Int64?) {
        selectedId = id
        draft = presets.first { $0.id == id }
        result = nil
    }

    var isDirty: Bool { draft != presets.first { $0.id == selectedId } }

    func saveDraft() {
        guard let draft else { return }
        let saved = store.save(draft)
        presets = store.generatorPresets()
        select(saved.id)
    }

    func newPreset() {
        let saved = store.save(GeneratorPreset(name: "New Preset", root: .group(matchAll: true, [.trackCount(20, comparison: .about, strength: 1)])))
        presets = store.generatorPresets()
        select(saved.id)
    }

    func deletePreset() {
        guard let id = selectedId else { return }
        store.deleteGeneratorPreset(id: id)
        presets = store.generatorPresets()
        select(presets.first?.id)
    }

    func run() {
        guard let root = draft?.root, !running else { return }
        running = true
        result = nil
        let db = env.database
        let iterations = Int(1000 * pow(2, quality))
        Task {
            let universe = try? await TrackUniverse.load(db, queries: root.searchQueries)
            let output = await Task.detached { () -> PlaylistGenerator.Result? in
                guard let universe else { return nil }
                var rng = SystemRandomNumberGenerator()
                return PlaylistGenerator(root: root, universe: universe).run(iterations: iterations, rng: &rng)
            }.value
            if let output, let universe {
                let ms = output.trackIds.reduce(0) { $0 + (universe.byId[$1]?.durationMs ?? 0) }
                result = (output.trackIds, output.quality, ms)
            }
            running = false
        }
    }

    func use(_ mode: Commands.AddMode) {
        guard let ids = result?.ids else { return }
        let tracks = (try? env.database.tracks(ids: ids)) ?? []
        Commands.addToPlaylist(tracks, mode: mode)
    }
}

struct GeneratorView: View {
    @Bindable var model: GeneratorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Preset", selection: Binding(get: { model.selectedId }, set: { model.select($0) })) {
                    ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                Button { model.newPreset() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("New preset")
                Button { model.deletePreset() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete preset")
            }
            .padding(8)
            Divider()
            if model.draft != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.draft?.name = $0 }))
                        ConstraintEditor(constraint: Binding(get: { model.draft!.root }, set: { model.draft?.root = $0 }), onRemove: nil)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Quality").font(.caption)
                    Slider(value: $model.quality, in: 0...4).help("Higher quality searches longer")
                }
                HStack {
                    Button("Save Preset") { model.saveDraft() }.disabled(!model.isDirty)
                    Spacer()
                    Button("Generate") { model.run() }.keyboardShortcut(.defaultAction).disabled(model.running || model.draft == nil)
                }
                if model.running { ProgressView().progressViewStyle(.linear) }
                if let result = model.result {
                    Text("\(result.ids.count) tracks · \(TimeFormatting.durationMs(result.duration)) · \(Int((result.quality * 100).rounded()))% of the constraints met")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Add to Playlist") { model.use(.append) }
                        Button("Replace Playlist") { model.use(.replace) }
                    }
                }
            }
            .padding(10)
        }
    }
}

/// Recursive editor for generator constraints, laid out to fit the narrow Media Sources pane.
struct ConstraintEditor: View {
    @Binding var constraint: GeneratorConstraint
    let onRemove: (() -> Void)?

    enum Kind: String, CaseIterable, Identifiable {
        case group = "Group", matchTags = "Match Tags", duration = "Duration", trackCount = "Playlist Length",
             totalSize = "Total Size", duplicates = "Prevent Duplicates", spread = "Spread Artists", checkpoint = "Checkpoint"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch constraint {
        case .group: .group
        case .matchTags: .matchTags
        case .duration: .duration
        case .trackCount: .trackCount
        case .totalSize: .totalSize
        case .preventDuplicates: .duplicates
        case .spreadArtists: .spread
        case .checkpoint: .checkpoint
        }
    }

    private static func make(_ kind: Kind) -> GeneratorConstraint {
        switch kind {
        case .group: .group(matchAll: true, [])
        case .matchTags: .matchTags(query: "", invert: false, strength: 1)
        case .duration: .duration(seconds: 3600, comparison: .about, strength: 1)
        case .trackCount: .trackCount(20, comparison: .about, strength: 1)
        case .totalSize: .totalSize(megabytes: 700, comparison: .atMost, strength: 1)
        case .duplicates: .preventDuplicates(.track)
        case .spread: .spreadArtists(strength: 0.7)
        case .checkpoint: .checkpoint(query: "", atSeconds: 0, strength: 1)
        }
    }

    var body: some View {
        if case .group(let all, let children) = constraint {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    kindPicker
                    Picker("", selection: Binding(get: { all }, set: { constraint = .group(matchAll: $0, children) })) {
                        Text("all of").tag(true)
                        Text("any of").tag(false)
                    }
                    .labelsHidden().fixedSize()
                    Spacer(minLength: 0)
                    removeButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(children.indices, id: \.self) { i in
                        AnyView(ConstraintEditor(constraint: Binding(get: { children.indices.contains(i) ? children[i] : .preventDuplicates(.track) }, set: { new in
                            var c = children
                            c[i] = new
                            constraint = .group(matchAll: all, c)
                        }), onRemove: {
                            var c = children
                            c.remove(at: i)
                            constraint = .group(matchAll: all, c)
                        }))
                    }
                    Button {
                        constraint = .group(matchAll: all, children + [.matchTags(query: "", invert: false, strength: 1)])
                    } label: { Label("Add Constraint", systemImage: "plus.circle") }
                    .buttonStyle(.borderless).font(.caption)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    kindPicker
                    Spacer(minLength: 0)
                    removeButton
                }
                detail
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
    }

    private var kindPicker: some View {
        Picker("", selection: Binding(get: { kind }, set: { constraint = Self.make($0) })) {
            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder private var removeButton: some View {
        if let onRemove {
            Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove")
        }
    }

    private func comparisonPicker(_ selection: Binding<GeneratorConstraint.Comparison>) -> some View {
        Picker("", selection: selection) {
            ForEach(GeneratorConstraint.Comparison.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func strengthRow(_ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text("Strength").font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
        }
        .help("How much this constraint matters")
    }

    @ViewBuilder private var detail: some View {
        switch constraint {
        case .group:
            EmptyView()
        case .matchTags(let q, let invert, let s):
            HStack(spacing: 6) {
                Toggle("Not", isOn: Binding(get: { invert }, set: { constraint = .matchTags(query: q, invert: $0, strength: s) }))
                    .toggleStyle(.checkbox)
                TextField("Filter, e.g. genre:rock", text: Binding(get: { q }, set: { constraint = .matchTags(query: $0, invert: invert, strength: s) }))
            }
            strengthRow(Binding(get: { s }, set: { constraint = .matchTags(query: q, invert: invert, strength: $0) }))
        case .duration(let secs, let c, let s):
            HStack(spacing: 6) {
                comparisonPicker(Binding(get: { c }, set: { constraint = .duration(seconds: secs, comparison: $0, strength: s) }))
                TextField("Minutes", value: Binding(get: { secs / 60 }, set: { constraint = .duration(seconds: max(1, $0) * 60, comparison: c, strength: s) }),
                          format: .number).frame(width: 50)
                Text("minutes")
            }
            strengthRow(Binding(get: { s }, set: { constraint = .duration(seconds: secs, comparison: c, strength: $0) }))
        case .trackCount(let n, let c, let s):
            HStack(spacing: 6) {
                comparisonPicker(Binding(get: { c }, set: { constraint = .trackCount(n, comparison: $0, strength: s) }))
                TextField("Tracks", value: Binding(get: { n }, set: { constraint = .trackCount(max(1, $0), comparison: c, strength: s) }),
                          format: .number).frame(width: 50)
                Text("tracks")
            }
            strengthRow(Binding(get: { s }, set: { constraint = .trackCount(n, comparison: c, strength: $0) }))
        case .totalSize(let mb, let c, let s):
            HStack(spacing: 6) {
                comparisonPicker(Binding(get: { c }, set: { constraint = .totalSize(megabytes: mb, comparison: $0, strength: s) }))
                TextField("MB", value: Binding(get: { mb }, set: { constraint = .totalSize(megabytes: max(1, $0), comparison: c, strength: s) }),
                          format: .number).frame(width: 60)
                Text("MB")
            }
            strengthRow(Binding(get: { s }, set: { constraint = .totalSize(megabytes: mb, comparison: c, strength: $0) }))
        case .preventDuplicates(let field):
            Picker("No two tracks with the same", selection: Binding(get: { field }, set: { constraint = .preventDuplicates($0) })) {
                ForEach(GeneratorConstraint.DuplicateField.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .font(.caption)
            .fixedSize()
        case .spreadArtists(let s):
            strengthRow(Binding(get: { s }, set: { constraint = .spreadArtists(strength: $0) }))
        case .checkpoint(let q, let at, let s):
            TextField("Filter, e.g. title:intro", text: Binding(get: { q }, set: { constraint = .checkpoint(query: $0, atSeconds: at, strength: s) }))
            HStack(spacing: 6) {
                Text("starts at")
                TextField("Minute", value: Binding(get: { at / 60 }, set: { constraint = .checkpoint(query: q, atSeconds: max(0, $0) * 60, strength: s) }),
                          format: .number).frame(width: 50)
                Text("minutes")
            }
            strengthRow(Binding(get: { s }, set: { constraint = .checkpoint(query: q, atSeconds: at, strength: $0) }))
        }
    }
}
