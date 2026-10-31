import Foundation
import GRDB

/// Turns opened or dropped URLs (audio files, folders, playlist files, streams) into playlist items,
/// and saves / restores the current playlist session.
public enum PlaylistLoader {
    /// Expands folders (recursively, in natural path order) and playlist files, then resolves the
    /// result against the collection.
    @concurrent
    public static func items(for urls: [URL], database: LibraryDatabase) async -> [PlaylistItem] {
        var entries: [PlaylistFileEntry] = []
        for url in urls { expand(url, into: &entries, depth: 0) }
        return resolve(entries, database: database)
    }

    static func expand(_ url: URL, into entries: inout [PlaylistFileEntry], depth: Int) {
        guard url.isFileURL else {
            entries.append(PlaylistFileEntry(url: url))
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var files: [URL] = []
            while let file = enumerator?.nextObject() as? URL {
                if AudioFileTypes.isAudio(file) { files.append(file) }
            }
            files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            entries += files.map { PlaylistFileEntry(url: $0) }
        } else if PlaylistFileFormat.from(url: url) != nil {
            guard depth < 4 else { return }
            for entry in (try? PlaylistFile.read(from: url)) ?? [] {
                if entry.url.isFileURL && PlaylistFileFormat.from(url: entry.url) != nil {
                    expand(entry.url, into: &entries, depth: depth + 1)
                } else {
                    entries.append(entry)
                }
            }
        } else if AudioFileTypes.isAudio(url) {
            entries.append(PlaylistFileEntry(url: url))
        }
    }

    /// Collection tracks are matched by path; other local files are read directly; anything else
    /// becomes a stream item carrying the entry's title.
    public static func resolve(_ entries: [PlaylistFileEntry], database: LibraryDatabase) -> [PlaylistItem] {
        let paths = entries.filter(\.url.isFileURL).map { $0.url.standardizedFileURL.path }
        let known = (try? database.writer.read { try CollectionQueries.tracks($0, paths: paths) }) ?? [:]
        return entries.compactMap { entry in
            item(for: entry, known: known, id: PlaylistItemID())
        }
    }

    private static func item(for entry: PlaylistFileEntry, known: [String: TrackWithStatistics], id: PlaylistItemID) -> PlaylistItem? {
        guard entry.url.isFileURL else {
            var item = PlaylistItem.stream(url: entry.url, title: entry.title, id: id)
            if let artist = entry.artist { item.track.artist = artist }
            if let ms = entry.durationMs { item.track.durationMs = ms }
            item.track.updateDerivedFields()
            return item
        }
        let path = entry.url.standardizedFileURL.path
        if let found = known[path] {
            return PlaylistItem(id: id, track: found.track, statistics: found.statistics, source: .collection)
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var track = (try? TagReader.read(url: entry.url).track) ?? Track(path: path)
        track.path = path
        if track.title.isEmpty, let title = entry.title { track.title = title }
        track.updateDerivedFields()
        return PlaylistItem(id: id, track: track, source: .file)
    }

    // MARK: Session

    /// The current playlist as saved between launches.
    public struct Session: Codable, Sendable {
        public struct Entry: Codable, Sendable {
            public var id: UUID
            public var trackId: Int64?
            public var url: String
            public var source: PlaylistItemSource
            public var title: String?
            public var artist: String?
            public var durationMs: Int?
        }

        public var entries: [Entry]
        public var activeID: UUID?
        public var queue: [UUID]
        public var stopAfterID: UUID?
        /// Playback position of the active item when the app quit while playing.
        public var position: Double?
        public var wasPlaying: Bool

        @MainActor
        public init(model: PlaylistModel, position: Double?, wasPlaying: Bool) {
            entries = model.items.map { item in
                Entry(id: item.id.rawValue, trackId: item.source == .collection ? item.track.id : nil,
                      url: item.url.absoluteString, source: item.source,
                      title: item.isStream ? item.track.title : nil, artist: item.isStream ? item.track.artist : nil,
                      durationMs: item.isStream ? item.track.durationMs : nil)
            }
            activeID = model.activeID?.rawValue
            queue = model.queue.map(\.rawValue)
            stopAfterID = model.stopAfterID?.rawValue
            self.position = position
            self.wasPlaying = wasPlaying
        }
    }

    static let sessionKey = "playlistSession"

    public static func saveSession(_ session: Session, database: LibraryDatabase) throws {
        let data = try JSONEncoder().encode(session)
        try database.writer.write { db in
            try AppStateRecord(key: sessionKey, value: data).save(db)
        }
    }

    public static func loadSession(database: LibraryDatabase) -> Session? {
        guard let record = try? database.writer.read({ try AppStateRecord.fetchOne($0, key: sessionKey) }),
              let data = record.value else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    /// Rebuilds the saved items. Collection tracks are re-read from the database so edits made
    /// since are picked up; tracks no longer in the collection fall back to their file.
    @concurrent
    public static func items(for session: Session, database: LibraryDatabase) async -> [PlaylistItem] {
        let ids = session.entries.compactMap(\.trackId)
        let tracks = (try? await database.writer.read { try CollectionQueries.tracks($0, ids: ids) }) ?? []
        let byId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.track.id!, $0) })
        return session.entries.compactMap { entry in
            let id = PlaylistItemID(rawValue: entry.id)
            if let trackId = entry.trackId, let found = byId[trackId] {
                return PlaylistItem(id: id, track: found.track, statistics: found.statistics, source: .collection)
            }
            guard let url = URL(string: entry.url) else { return nil }
            let fileEntry = PlaylistFileEntry(url: url, title: entry.title, artist: entry.artist, durationMs: entry.durationMs)
            guard var item = item(for: fileEntry, known: [:], id: id) else { return nil }
            if entry.source == .podcast { item.source = .podcast }
            return item
        }
    }
}
