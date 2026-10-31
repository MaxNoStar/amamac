// Debug builds and tests only: Release builds compile this out.
#if DEBUG
import AmamacLibrary
import Foundation

/// A small made-up collection for the README screenshots (`AMAMAC_SNAPSHOT_SHOWCASE=1 make
/// snapshot`): six albums with designed covers and realistic track lengths. The tracks are
/// silent and low-rate, so the whole library is a few hundred kilobytes.
public enum ShowcaseLibrary {
    public struct Album: Sendable {
        public let artist: String
        public let title: String
        public let year: Int
        public let genre: String
        public let cover: ShowcaseCovers.Style
        /// Track titles with their lengths in seconds.
        public let tracks: [(String, Double)]
    }

    /// The artist the hero screenshot plays; Wikipedia's stub has an article about him.
    public static let heroArtist = "MC Chops"

    public static let albums: [Album] = [
        Album(artist: "MC Chops", title: "Handlebar Anthems", year: 2026, genre: "Rock", cover: .sunburst, tracks: [
            ("Born to Oink", 214), ("Mustache Rides Again", 247), ("Three Chords & a Snout", 168),
            ("Trotter Boogie", 231), ("Hog Wild Heart", 262),
        ]),
        Album(artist: "Hamish & the Hooves", title: "Velvet Bristles", year: 2022, genre: "Blues Rock", cover: .rings, tracks: [
            ("Slow Roast Blues", 298), ("Pink Moon Over the Pen", 255), ("Crackling", 191), ("Last Call at the Trough", 312),
        ]),
        Album(artist: "Oinkwave", title: "Neon Pastures", year: 2025, genre: "Synthwave", cover: .synthSun, tracks: [
            ("Night Drive to the Farm", 276), ("Pastel Silo", 223), ("Chrome Snout", 241), ("Static Meadow", 204),
            ("Moonlit Mud", 287),
        ]),
        Album(artist: "Lady Truffle", title: "Sunday Morning Slop", year: 2021, genre: "Soul", cover: .bokeh, tracks: [
            ("Good Morning, Sty", 233), ("Buttered Corn", 197), ("Sweet Potato Pie", 244), ("Lazy Tail", 268),
        ]),
        Album(artist: "The Rasher Kids", title: "Pig Pen Riot", year: 2019, genre: "Punk", cover: .stripes, tracks: [
            ("Squeal Like You Mean It", 151), ("Pig Pen Riot", 139), ("No Pork Futures", 162),
        ]),
        Album(artist: "Smokehouse Swing Club", title: "Low and Slow", year: 2018, genre: "Jazz", cover: .smoke, tracks: [
            ("Smokehouse Swing", 256), ("Hickory Lullaby", 301), ("Brisket Bossa", 239), ("Low and Slow", 284),
        ]),
    ]

    /// Writes every album (silent FLAC files plus a `cover.png`) under `root`.
    public static func build(at root: URL) throws {
        for album in albums {
            let folder = "\(album.artist)/\(album.title)"
            for (index, (title, seconds)) in album.tracks.enumerated() {
                var tags = TagChanges()
                tags.title = title
                tags.artist = album.artist
                tags.album = album.title
                tags.trackNumber = index + 1
                tags.year = album.year
                tags.genre = album.genre
                let name = String(format: "%02d %@.flac", index + 1, title.replacingOccurrences(of: "/", with: "-"))
                try AudioFixtures.make(.init("\(folder)/\(name)", seconds: seconds, sampleRate: 8_000, channels: 1,
                                             amplitude: 0, tags: tags), in: root)
            }
            try ShowcaseCovers.png(album.cover, size: 512).write(to: root.appendingPathComponent("\(folder)/cover.png"))
        }
    }
}
#endif
