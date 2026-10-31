import AppKit
import AmamacCore
import GRDB

/// Shared services for the app (one per process).
@MainActor
final class AppEnvironment {
    static var shared: AppEnvironment!

    let dataDirectory: URL
    let cacheDirectory: URL
    let settings: AppSettings
    let database: LibraryDatabase
    let scanner: CollectionScanner
    let covers: CoverStore
    let coverImages: CoverImageCache
    let status = StatusCenter()
    let playlist = PlaylistModel()
    let proxy: PlaylistProxy
    let navigator: PlaylistNavigator
    let player: PlayerController
    let http: HTTPClient
    let lyrics: LyricsService
    private var watcher: FolderWatcher?

    /// Posted when the collection database changed (scan, tag edit, statistics).
    static let collectionChanged = Notification.Name("amamacCollectionChanged")

    /// `httpConfiguration` is replaced by a stub in snapshot runs.
    init(dataDirectory: URL, defaults: UserDefaults, httpConfiguration: URLSessionConfiguration = .ephemeral) throws {
        self.dataDirectory = dataDirectory
        cacheDirectory = dataDirectory.appendingPathComponent("Caches")
        settings = AppSettings(defaults: defaults)
        database = try LibraryDatabase.open(at: dataDirectory.appendingPathComponent("collection.sqlite"))
        scanner = CollectionScanner(database: database)
        covers = CoverStore(database: database, cacheDirectory: cacheDirectory.appendingPathComponent("covers"))
        coverImages = CoverImageCache(store: covers)
        proxy = PlaylistProxy(model: playlist)
        navigator = PlaylistNavigator(proxy: proxy)
        navigator.progression = settings.trackProgression
        navigator.favor = settings.favor
        player = PlayerController(model: playlist, proxy: proxy, navigator: navigator, database: database, settings: settings)
        http = HTTPClient(cacheDirectory: cacheDirectory.appendingPathComponent("http"), configuration: httpConfiguration)
        lyrics = LyricsService(database: database, http: http)
    }

    func wikipedia() -> WikipediaClient {
        WikipediaClient(http: http, language: settings.string(AppSettings.Key.wikipediaLanguage) ?? "en")
    }

    static func defaultDataDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Amamac")
    }

    // MARK: Collection

    var collectionFolders: [CollectionFolder] {
        (try? database.writer.read { try CollectionFolder.fetchAll($0) }) ?? []
    }

    func setCollectionFolders(_ paths: [String]) {
        try? database.writer.write { db in
            let existing = try CollectionFolder.fetchAll(db)
            for folder in existing where !paths.contains(folder.path) { try folder.delete(db) }
            for path in paths where !existing.contains(where: { $0.path == path }) {
                var folder = CollectionFolder(path: path)
                try folder.insert(db)
            }
        }
        startWatching()
    }

    /// Scans the collection, reporting progress in the Media Sources strip.
    func scanCollection(full: Bool = false, onlyPaths: [String]? = nil) {
        let status = self.status
        let token = status.beginTask(full ? "Rescanning collection" : "Updating collection")
        let progress: @Sendable (ScanProgress) -> Void = { p in
            Task { @MainActor in status.update(token, phase: p.phase, fraction: p.total > 0 ? p.fraction : nil) }
        }
        Task {
            do {
                let result = try await scanner.scan(full: full, onlyPaths: onlyPaths, progress: progress)
                status.endTask(token)
                if result.skipped { return }
                if !result.unreachableRoots.isEmpty {
                    status.showMessage("Some collection folders are not reachable: \(result.unreachableRoots.joined(separator: ", "))")
                }
                if result.changed {
                    await covers.invalidate()
                    coverImages.removeAll()
                    NotificationCenter.default.post(name: Self.collectionChanged, object: nil)
                }
                if !result.failed.isEmpty {
                    status.showMessage("\(result.failed.count) files could not be read.")
                }
            } catch {
                status.endTask(token)
                status.showMessage("Collection scan failed: \(error.localizedDescription)")
            }
        }
    }

    func startWatching() {
        let folders = collectionFolders.filter(\.watch).map(\.path)
        if watcher == nil {
            watcher = FolderWatcher { dirs in
                Task { @MainActor in AppEnvironment.shared.scanCollection(onlyPaths: dirs) }
            }
        }
        watcher?.watch(paths: folders)
    }

    func ignoreWatcherEvents(for path: String) { watcher?.ignore(path: path) }
}

/// Progress tasks and short messages shown at the bottom of Media Sources.
@MainActor
@Observable
final class StatusCenter {
    struct TaskInfo: Identifiable {
        let id: UUID
        var title: String
        var phase: String
        var fraction: Double?
    }

    private(set) var tasks: [TaskInfo] = []
    private(set) var message: String?
    @ObservationIgnored private var messageToken = UUID()

    func beginTask(_ title: String) -> UUID {
        let id = UUID()
        tasks.append(TaskInfo(id: id, title: title, phase: "", fraction: nil))
        return id
    }

    func update(_ id: UUID, phase: String, fraction: Double?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].phase = phase
        tasks[i].fraction = fraction
    }

    func endTask(_ id: UUID) { tasks.removeAll { $0.id == id } }

    func showMessage(_ text: String, seconds: Double = 6) {
        message = text
        let token = UUID()
        messageToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if self.messageToken == token { self.message = nil }
        }
    }
}

/// Loads cover thumbnails from `CoverStore` into NSImages, memoised per album and size.
@MainActor
final class CoverImageCache {
    let store: CoverStore
    private let cache = NSCache<NSString, NSImage>()
    private var missing = Set<String>()
    private var pending: [String: [(NSImage?) -> Void]] = [:]

    init(store: CoverStore) {
        self.store = store
        cache.countLimit = 600
    }

    func removeAll() {
        cache.removeAllObjects()
        missing.removeAll()
    }

    func invalidate(albumKey: String) {
        for size in [32, 48, 64, 100, 128, 200, 300, 600] { cache.removeObject(forKey: "\(albumKey)#\(size)" as NSString) }
        missing = missing.filter { !$0.hasPrefix(albumKey + "#") }
        Task { await store.invalidate(albumKey: albumKey) }
    }

    /// Returns a cached image immediately, or nil and calls `completion` once loaded.
    func image(albumKey: String, size: Int, completion: @escaping (NSImage?) -> Void) -> NSImage? {
        let key = "\(albumKey)#\(size)"
        if let image = cache.object(forKey: key as NSString) { return image }
        if missing.contains(key) { return nil }
        if pending[key] != nil {
            pending[key]!.append(completion)
            return nil
        }
        pending[key] = [completion]
        let store = self.store
        Task {
            let url = await store.cover(albumKey: albumKey, size: size * 2)
            let image = url.flatMap { NSImage(contentsOf: $0) }
            if let image { cache.setObject(image, forKey: key as NSString) } else { missing.insert(key) }
            let callbacks = pending.removeValue(forKey: key) ?? []
            for cb in callbacks { cb(image) }
        }
        return nil
    }

    func image(albumKey: String, size: Int) async -> NSImage? {
        let key = "\(albumKey)#\(size)"
        if let image = cache.object(forKey: key as NSString) { return image }
        if missing.contains(key) { return nil }
        return await withCheckedContinuation { cont in
            if let img = image(albumKey: albumKey, size: size, completion: { cont.resume(returning: $0) }) {
                cont.resume(returning: img)
            }
        }
    }
}
