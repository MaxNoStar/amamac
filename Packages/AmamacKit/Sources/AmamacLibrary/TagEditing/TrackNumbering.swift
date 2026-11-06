import Foundation

/// "Number Tracks" in the tag editor: numbers tracks 1…N on each disc.
public enum TrackNumbering {
    public struct Input: Sendable, Hashable {
        public var discNumber: Int
        public var trackNumber: Int
        public var fileName: String

        public init(discNumber: Int, trackNumber: Int, fileName: String) {
            self.discNumber = discNumber
            self.trackNumber = trackNumber
            self.fileName = fileName
        }
    }

    public struct Number: Sendable, Hashable {
        public var trackNumber: Int
        /// Tracks on the same disc ("of N").
        public var trackTotal: Int

        public init(trackNumber: Int, trackTotal: Int) {
            self.trackNumber = trackNumber
            self.trackTotal = trackTotal
        }
    }

    /// One number per input, in input order. Tracks are ordered by disc, then by their current
    /// track number (unnumbered ones last), then by file name as Finder sorts it.
    public static func number(_ tracks: [Input]) -> [Number] {
        let order = tracks.indices.sorted { a, b in
            let x = tracks[a], y = tracks[b]
            if x.discNumber != y.discNumber { return x.discNumber < y.discNumber }
            let xn = x.trackNumber > 0 ? x.trackNumber : Int.max, yn = y.trackNumber > 0 ? y.trackNumber : Int.max
            if xn != yn { return xn < yn }
            let byName = x.fileName.localizedStandardCompare(y.fileName)
            return byName == .orderedSame ? a < b : byName == .orderedAscending
        }
        var totals: [Int: Int] = [:]
        for track in tracks { totals[track.discNumber, default: 0] += 1 }
        var result = [Number](repeating: Number(trackNumber: 0, trackTotal: 0), count: tracks.count)
        var next: [Int: Int] = [:]
        for index in order {
            let disc = tracks[index].discNumber
            next[disc, default: 0] += 1
            result[index] = Number(trackNumber: next[disc] ?? 1, trackTotal: totals[disc] ?? 0)
        }
        return result
    }
}
