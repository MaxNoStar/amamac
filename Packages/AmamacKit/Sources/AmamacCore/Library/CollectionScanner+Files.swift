import CryptoKit
import Foundation
import GRDB

extension CollectionScanner {
    /// Marks albums as compilations when a folder holds one album title by three or more artists and
    /// no album artist is tagged.
    nonisolated func applyCompilationHeuristic(directories: Set<String>) async throws {
        try await database.writer.write { db in
            for dir in directories {
                let prefix = TextFolding.likeEscaped(dir + "/") + "%"
                let notDeeper = TextFolding.likeEscaped(dir + "/") + "%/%"
                var tracks = try Track.fetchAll(db, sql: "SELECT * FROM track WHERE path LIKE ? ESCAPE '\\' AND path NOT LIKE ? ESCAPE '\\'",
                                                arguments: [prefix, notDeeper])
                let byAlbum = Dictionary(grouping: tracks.indices) { TextFolding.fold(tracks[$0].album) }
                for (album, indexes) in byAlbum where !album.isEmpty {
                    let untagged = indexes.allSatisfy { tracks[$0].albumArtist.isEmpty }
                    let artists = Set(indexes.map { TextFolding.fold(tracks[$0].artist) })
                    guard untagged, artists.count >= 3 else { continue }
                    for i in indexes where !tracks[i].compilation {
                        tracks[i].compilation = true
                        tracks[i].albumArtistSort = ""
                        tracks[i].updateDerivedFields()
                        try tracks[i].update(db)
                    }
                }
            }
        }
    }

    static func enumerate(root: String, recursive: Bool) -> (audio: [FileInfo], playlists: [String]) {
        var audio: [FileInfo] = []
        var playlists: [String] = []
        let url = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: options) else {
            return ([], [])
        }
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if PlaylistFileFormat(rawValue: ext) != nil {
                playlists.append(fileURL.standardizedFileURL.path)
                continue
            }
            guard AudioFileTypes.extensions.contains(ext),
                  let values = try? fileURL.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            if fileURL.lastPathComponent.hasPrefix("._") { continue }
            audio.append(FileInfo(path: fileURL.standardizedFileURL.path,
                                  mtime: values.contentModificationDate ?? Date(),
                                  size: Int64(values.fileSize ?? 0)))
        }
        return (audio, playlists)
    }

    /// Content hash of size + first and last 64 KB; survives renames and moves.
    public static func uniqueId(for url: URL, size: Int64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        let chunk = 65_536
        if let head = try? handle.read(upToCount: chunk) { hasher.update(data: head) }
        if size > Int64(chunk) * 2 {
            try? handle.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let tail = try? handle.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return Hashing.hex(hasher.finalize(), bytes: 16)
    }
}
