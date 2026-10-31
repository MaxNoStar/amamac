import Foundation
@testable import AmamacCore

func makeTrack(_ title: String, artist: String = "Artist", album: String = "Album", track: Int = 1,
               disc: Int = 0, year: Int = 2000, genre: String = "Rock", albumArtist: String = "",
               durationMs: Int = 180_000, compilation: Bool = false, path: String? = nil, id: Int64? = nil) -> Track {
    var t = Track(id: id, path: path ?? "/music/\(artist)/\(album)/\(track) \(title).flac", title: title, artist: artist,
                  albumArtist: albumArtist, album: album, genre: genre, year: year, trackNumber: track,
                  discNumber: disc, compilation: compilation, durationMs: durationMs, format: "flac")
    t.updateDerivedFields()
    return t
}

func makeItem(_ title: String, album: String = "Album", artist: String = "Artist", track: Int = 1,
              stats: TrackStatistics? = nil) -> PlaylistItem {
    PlaylistItem(track: makeTrack(title, artist: artist, album: album, track: track), statistics: stats)
}

func temporaryDirectory(_ name: String = #function) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("amamac-tests")
        .appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
