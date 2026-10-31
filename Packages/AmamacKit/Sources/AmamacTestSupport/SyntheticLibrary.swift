import AmamacBase
import AmamacDatabase
import AmamacModels
import Foundation
import GRDB

/// Fills a database with fake tracks (no files) for performance checks.
public enum SyntheticLibrary {
    public static func populate(_ database: LibraryDatabase, trackCount: Int = 20_000, seed: UInt64 = 7) throws {
        var rng = SplitMix64(seed: seed)
        let genres = ["Rock", "Pop", "Jazz", "Electronic", "Classical", "Hip-Hop", "Folk", "Metal", "Ambient", "Blues"]
        let words = ["Blue", "Night", "Fire", "Dream", "Echo", "Glass", "River", "Static", "Velvet", "Neon", "Silver",
                     "Ghost", "Summer", "Paper", "Iron", "Wild", "Golden", "Hollow", "Electric", "Quiet"]
        func phrase(_ n: Int) -> String { (0..<n).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ") }
        let now = Date()
        try database.writer.write { db in
            var made = 0
            var artistIndex = 0
            while made < trackCount {
                artistIndex += 1
                let artist = "The \(phrase(1)) \(phrase(1))s \(artistIndex)"
                for a in 0..<Int(2 + rng.next() % 4) where made < trackCount {
                    let album = phrase(2)
                    let year = 1965 + Int(rng.next() % 60)
                    let genre = genres[Int(rng.next() % UInt64(genres.count))]
                    for n in 1...Int(8 + rng.next() % 6) where made < trackCount {
                        var t = Track(path: "/Synthetic/\(artist)/\(album) \(a)/\(n).flac", uniqueId: UUID().uuidString,
                                      title: phrase(Int(1 + rng.next() % 3)), artist: artist, album: album, genre: genre,
                                      year: year, trackNumber: n, durationMs: Int(120_000 + rng.next() % 300_000),
                                      format: "flac", bitrate: 900, sampleRate: 44_100, channels: 2, fileSize: 30_000_000,
                                      mtime: now, dateAdded: now.addingTimeInterval(-Double(rng.next() % 31_536_000)))
                        t.updateDerivedFields()
                        try t.insert(db)
                        if rng.next() % 3 == 0 {
                            try TrackStatistics(trackId: t.id!, rating: Int(rng.next() % 11), score: Double(rng.next() % 100),
                                                playCount: Int(rng.next() % 40), lastPlayed: now.addingTimeInterval(-Double(rng.next() % 9_000_000))).insert(db)
                        }
                        made += 1
                    }
                }
            }
        }
    }
}
