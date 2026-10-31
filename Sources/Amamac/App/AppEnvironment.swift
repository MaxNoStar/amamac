import AmamacBase
import AmamacDatabase
import AmamacLibrary
import AmamacPlaylist
import AmamacWeb
import AppKit

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
    private(set) lazy var dynamicMode = DynamicModeController(env: self)
    private(set) lazy var equalizer = EqualizerController(settings: settings, engine: player.local)
    private(set) lazy var podcasts = PodcastController(env: self)
    private var watcher: FolderWatcher?

    /// Posted when the collection database changed (scan, tag edit, statistics).
    static let collectionChanged = Notification.Name("amamacCollectionChanged")
    /// Posted with the album key as object when an album's cover was set, fetched or unset.
    static let coverChanged = Notification.Name("amamacCoverChanged")

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
        (try? database.collectionFolders()) ?? []
    }

    func setCollectionFolders(_ paths: [String]) {
        try? database.setCollectionFolders(paths: paths)
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

