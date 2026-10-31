import AmamacBase
import AmamacLibrary
import AmamacModels
import AppKit
import SwiftUI

/// Media Sources › Files: browse folders and add audio or playlist files.
final class FileBrowserPage: NSViewController, MediaSourcePage {
    let model: FileBrowserModel

    init(env: AppEnvironment) {
        model = FileBrowserModel(env: env)
        super.init(nibName: nil, bundle: nil)
        title = MediaCategory.files.title
    }

    required init?(coder: NSCoder) { fatalError() }

    var crumbTitle: String { MediaCategory.files.title }
    var crumbSymbol: String { MediaCategory.files.symbol }

    override func loadView() {
        let host = NSHostingView(rootView: FileBrowserView(model: model))
        host.sizingOptions = []
        view = host
    }
}

@MainActor
@Observable
final class FileBrowserModel {
    struct Entry: Identifiable, Hashable {
        var url: URL
        var isFolder: Bool
        var id: URL { url }
        var kind: Kind {
            if isFolder { return .folder }
            return PlaylistFileFormat.from(url: url) != nil ? .playlist : .audio
        }
        enum Kind { case folder, audio, playlist }
    }

    let env: AppEnvironment
    private(set) var current: URL
    private(set) var entries: [Entry] = []
    private(set) var error: String?
    var filter = ""
    var selection: Set<URL> = []
    @ObservationIgnored private var back: [URL] = []
    @ObservationIgnored private var forward: [URL] = []
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    init(env: AppEnvironment) {
        self.env = env
        let start = env.settings.string(AppSettings.Key.fileBrowserFolder).map { URL(fileURLWithPath: $0) }
            ?? env.collectionFolders.first.map { URL(fileURLWithPath: $0.path) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        current = start
        load()
    }

    var visibleEntries: [Entry] {
        let f = TextFolding.fold(filter.trimmingCharacters(in: .whitespaces))
        guard !f.isEmpty else { return entries }
        return entries.filter { TextFolding.fold($0.url.lastPathComponent).contains(f) }
    }

    /// Folder chain from the volume root to the current folder.
    var pathComponents: [URL] {
        var chain: [URL] = []
        var url = current.standardizedFileURL
        while true {
            chain.insert(url, at: 0)
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path == url.path { break }
            url = parent
        }
        return chain
    }

    func go(to url: URL, record: Bool = true) {
        guard url.standardizedFileURL != current.standardizedFileURL else { return }
        if record {
            back.append(current)
            forward.removeAll()
        }
        current = url
        selection = []
        filter = ""
        load()
    }

    func goBack() {
        guard let url = back.popLast() else { return }
        forward.append(current)
        go(to: url, record: false)
    }

    func goForward() {
        guard let url = forward.popLast() else { return }
        back.append(current)
        go(to: url, record: false)
    }

    func goUp() { go(to: current.deletingLastPathComponent()) }

    func goHome() {
        go(to: env.collectionFolders.first.map { URL(fileURLWithPath: $0.path) } ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    func load() {
        canGoBack = !back.isEmpty
        canGoForward = !forward.isEmpty
        env.settings.set(current.path, AppSettings.Key.fileBrowserFolder)
        let folder = current
        Task {
            let result = await Task.detached { () -> Result<[Entry], Error> in
                do {
                    let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                           options: [.skipsHiddenFiles])
                    let entries = urls.compactMap { url -> Entry? in
                        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                        if values?.isDirectory == true && values?.isPackage != true { return Entry(url: url, isFolder: true) }
                        if AudioFileTypes.isAudio(url) || PlaylistFileFormat.from(url: url) != nil { return Entry(url: url, isFolder: false) }
                        return nil
                    }
                    return .success(entries.sorted {
                        if $0.isFolder != $1.isFolder { return $0.isFolder }
                        return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                    })
                } catch {
                    return .failure(error)
                }
            }.value
            guard folder == current else { return }
            switch result {
            case .success(let list):
                entries = list
                error = nil
            case .failure(let e):
                entries = []
                let code = (e as NSError).code
                error = code == NSFileReadNoPermissionError ? "Amamac needs permission to read this folder." : e.localizedDescription
            }
        }
    }

    func activate(_ entry: Entry) {
        if entry.isFolder { go(to: entry.url) } else { Commands.addURLs([entry.url], mode: .append) }
    }

    func urls(for targets: [Entry]) -> [URL] { targets.map(\.url) }

    func targets(clicked: Entry?) -> [Entry] {
        if let clicked, !selection.contains(clicked.url) { return [clicked] }
        return entries.filter { selection.contains($0.url) }
    }
}

struct FileBrowserView: View {
    @Bindable var model: FileBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.canGoBack).help("Back")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!model.canGoForward).help("Forward")
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }.help("Up one folder")
                Button { model.goHome() } label: { Image(systemName: "house") }.help("Home")
                Button { model.load() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
                Spacer(minLength: 4)
                Menu {
                    ForEach(model.pathComponents.reversed(), id: \.self) { url in
                        Button(url.path == "/" ? "/" : url.lastPathComponent) { model.go(to: url) }
                    }
                } label: {
                    Label(model.current.lastPathComponent.isEmpty ? "/" : model.current.lastPathComponent, systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            TextField("Filter", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            Divider()
            if let error = model.error {
                VStack(spacing: 6) {
                    Image(systemName: "lock").font(.title2).foregroundStyle(.secondary)
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.visibleEntries) { entry in
                        row(entry).tag(entry.url)
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: URL.self) { urls in
                    let targets = model.entries.filter { urls.contains($0.url) }
                    Button("Add to Playlist") { Commands.addURLs(targets.map(\.url), mode: .append) }
                    Button("Replace Playlist") { Commands.addURLs(targets.map(\.url), mode: .replace) }
                    Button("Queue") { Commands.addURLs(targets.map(\.url), mode: .queue) }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url)) }
                } primaryAction: { urls in
                    if let entry = model.entries.first(where: { urls.contains($0.url) }), urls.count == 1 {
                        model.activate(entry)
                    } else {
                        Commands.addURLs(Array(urls), mode: .append)
                    }
                }
            }
        }
    }

    private func row(_ entry: FileBrowserModel.Entry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.kind == .folder ? "folder.fill" : entry.kind == .playlist ? "music.note.list" : "music.note")
                .foregroundStyle(entry.kind == .folder ? Color.amamacAccent : Color.secondary)
                .frame(width: 16)
            Text(entry.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
        }
        .onDrag { NSItemProvider(object: entry.url as NSURL) }
    }
}
