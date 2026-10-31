import AmamacBase
import AmamacDatabase
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// Resolves album covers and caches thumbnails on disk. Lookup order: custom → embedded art →
/// folder image → fetched. Returns file URLs so callers on any thread can load images.
public actor CoverStore {
    public let database: LibraryDatabase
    public let cacheDirectory: URL
    /// Albums known to have no cover (cleared by `invalidate`).
    private var missing = Set<String>()
    private var inFlight: [String: Task<URL?, Never>] = [:]

    public static let folderImageNames = ["cover", "folder", "front", "album", "albumart", "albumartsmall", "thumb"]
    public static let imageExtensions = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff"]

    public init(database: LibraryDatabase, cacheDirectory: URL) {
        self.database = database
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    nonisolated func cacheKey(_ albumKey: String) -> String {
        Hashing.sha256Hex(albumKey, bytes: 12)
    }

    nonisolated func thumbnailURL(albumKey: String, size: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(cacheKey(albumKey))-\(size).jpg")
    }

    nonisolated func originalURL(albumKey: String) -> URL {
        cacheDirectory.appendingPathComponent("\(cacheKey(albumKey))-full")
    }

    /// Thumbnail of at most `size` pixels for the album, or nil when it has no cover.
    public func cover(albumKey: String, size: Int) async -> URL? {
        let thumb = thumbnailURL(albumKey: albumKey, size: size)
        if FileManager.default.fileExists(atPath: thumb.path) { return thumb }
        if missing.contains(albumKey) { return nil }
        let taskKey = "\(albumKey)#\(size)"
        if let task = inFlight[taskKey] { return await task.value }
        let task = Task<URL?, Never> { await self.makeThumbnail(albumKey: albumKey, size: size) }
        inFlight[taskKey] = task
        let url = await task.value
        inFlight[taskKey] = nil
        if url == nil { missing.insert(albumKey) }
        return url
    }

    /// Full-size cover image data (for Display Cover and embedding).
    public func originalImageData(albumKey: String) async -> Data? {
        await sourceImageData(albumKey: albumKey)
    }

    public func invalidate(albumKey: String? = nil) {
        if let albumKey {
            missing.remove(albumKey)
            let prefix = cacheKey(albumKey)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) {
                for f in files where f.hasPrefix(prefix) && f.hasSuffix(".jpg") {
                    try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(f))
                }
            }
        } else {
            missing.removeAll()
        }
    }

    /// Stores a user-chosen or fetched cover.
    public func setCover(albumKey: String, imageData: Data, source: AlbumCoverRecord.Source = .custom) async throws {
        let url = originalURL(albumKey: albumKey)
        try imageData.write(to: url, options: .atomic)
        try await database.writer.write { db in
            try AlbumCoverRecord(albumKey: albumKey, source: source, path: url.path).save(db)
        }
        invalidate(albumKey: albumKey)
    }

    /// "Unset Cover": hides embedded and folder art for this album.
    public func unsetCover(albumKey: String) async throws {
        try await database.writer.write { db in
            try AlbumCoverRecord(albumKey: albumKey, source: .unset, path: nil).save(db)
        }
        try? FileManager.default.removeItem(at: originalURL(albumKey: albumKey))
        invalidate(albumKey: albumKey)
        missing.insert(albumKey)
    }

    /// Removes a custom/fetched/unset override so automatic lookup applies again.
    public func resetCover(albumKey: String) async throws {
        _ = try await database.writer.write { db in
            try AlbumCoverRecord.deleteOne(db, key: albumKey)
        }
        try? FileManager.default.removeItem(at: originalURL(albumKey: albumKey))
        invalidate(albumKey: albumKey)
    }

    public func hasOverride(albumKey: String) async -> AlbumCoverRecord.Source? {
        try? await database.writer.read { db in try AlbumCoverRecord.fetchOne(db, key: albumKey)?.source }
    }

    private func makeThumbnail(albumKey: String, size: Int) async -> URL? {
        guard let data = await sourceImageData(albumKey: albumKey) else { return nil }
        let out = thumbnailURL(albumKey: albumKey, size: size)
        return Self.writeThumbnail(data: data, maxPixel: size, to: out) ? out : nil
    }

    private func sourceImageData(albumKey: String) async -> Data? {
        let record = try? await database.writer.read { db in try AlbumCoverRecord.fetchOne(db, key: albumKey) }
        if let record {
            if record.source == .unset { return nil }
            if let path = record.path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { return data }
        }
        let samples: [(path: String, embedded: Bool)] = (try? await database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT path, hasEmbeddedArt FROM track WHERE albumKey = ? ORDER BY hasEmbeddedArt DESC, discNumber, trackNumber LIMIT 8",
                             arguments: [albumKey]).map { ($0["path"], $0["hasEmbeddedArt"]) }
        }) ?? []
        for sample in samples where sample.embedded {
            if let data = TagReader.embeddedArt(url: URL(fileURLWithPath: sample.path)) { return data }
        }
        var checkedDirs = Set<String>()
        for sample in samples {
            let dir = (sample.path as NSString).deletingLastPathComponent
            guard checkedDirs.insert(dir).inserted else { continue }
            if let url = Self.folderImage(in: URL(fileURLWithPath: dir)), let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    /// Finds cover.jpg / folder.png etc. (case-insensitive), falling back to the only image in the
    /// folder.
    public static func folderImage(in directory: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) else { return nil }
        let images = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        for name in folderImageNames {
            if let match = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                return match
            }
        }
        for name in folderImageNames {
            if let match = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased().contains(name) }) {
                return match
            }
        }
        return images.count == 1 ? images[0] : nil
    }

    /// Writes a JPEG thumbnail with ImageIO.
    public static func writeThumbnail(data: Data, maxPixel: Int, to url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
