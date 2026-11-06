import AmamacModels
import Foundation

extension TagEditSession {
    /// One track's editable values, as text the way the editor shows them.
    public struct Values: Sendable, Hashable {
        public var title = "", artist = "", albumArtist = "", album = "", composer = "", genre = "", comment = ""
        public var trackNumber = "", trackTotal = "", discNumber = "", discTotal = "", bpm = ""
        public var releaseDate = "", originalDate = ""
        public var grouping = "", isrc = ""
        public var titleSort = "", artistSort = "", albumArtistSort = "", albumSort = ""
        public var compilation = false

        public init() {}

        /// From a collection track. Sort names are only known from the file (`Track` keeps folded
        /// sort keys), so they start empty unless given.
        public init(track t: Track, sortNames: SortNames? = nil) {
            title = t.title
            artist = t.artist
            albumArtist = t.albumArtist
            album = t.album
            composer = t.composer
            genre = t.genre
            comment = t.comment
            trackNumber = Self.text(t.trackNumber)
            trackTotal = Self.text(t.trackTotal)
            discNumber = Self.text(t.discNumber)
            discTotal = Self.text(t.discTotal)
            bpm = Self.text(t.bpm)
            releaseDate = t.releaseDate.isEmpty ? (ReleaseDate(year: t.year)?.isoString ?? "") : t.releaseDate
            originalDate = t.originalDate
            grouping = t.grouping
            isrc = t.isrc
            titleSort = sortNames?.title ?? ""
            artistSort = sortNames?.artist ?? ""
            albumArtistSort = sortNames?.albumArtist ?? ""
            albumSort = sortNames?.album ?? ""
            compilation = t.compilation
        }

        /// From the file's own tags.
        public init(read: TagReadResult) {
            self.init(track: read.track, sortNames: read.sortNames)
        }

        public subscript(field: Field) -> String {
            get { self[keyPath: field.keyPath] }
            set { self[keyPath: field.keyPath] = newValue }
        }

        static func text(_ n: Int) -> String { n > 0 ? String(n) : "" }
    }

    /// The text fields of `Values`.
    public enum Field: String, Sendable, CaseIterable {
        case title, artist, albumArtist, album, composer, genre, comment
        case trackNumber, trackTotal, discNumber, discTotal, bpm
        case releaseDate, originalDate
        case grouping, isrc, titleSort, artistSort, albumArtistSort, albumSort

        public enum Kind: Sendable { case text, number, date, isrc }

        public var kind: Kind {
            switch self {
            case .trackNumber, .trackTotal, .discNumber, .discTotal, .bpm: .number
            case .releaseDate, .originalDate: .date
            case .isrc: .isrc
            default: .text
            }
        }

        var keyPath: WritableKeyPath<Values, String> {
            switch self {
            case .title: \.title
            case .artist: \.artist
            case .albumArtist: \.albumArtist
            case .album: \.album
            case .composer: \.composer
            case .genre: \.genre
            case .comment: \.comment
            case .trackNumber: \.trackNumber
            case .trackTotal: \.trackTotal
            case .discNumber: \.discNumber
            case .discTotal: \.discTotal
            case .bpm: \.bpm
            case .releaseDate: \.releaseDate
            case .originalDate: \.originalDate
            case .grouping: \.grouping
            case .isrc: \.isrc
            case .titleSort: \.titleSort
            case .artistSort: \.artistSort
            case .albumArtistSort: \.albumArtistSort
            case .albumSort: \.albumSort
            }
        }

        /// Whether `text` can be written to this field.
        public func accepts(_ text: String) -> Bool {
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return true }
            switch kind {
            case .text: return true
            case .number: return Self.number(s) != nil
            case .date: return ReleaseDate(s) != nil
            case .isrc: return Self.isISRC(Self.normalizedISRC(s))
            }
        }

        /// The value as it is written and compared: trimmed, numbers and dates canonical, ISRC
        /// upper case without separators. Text the field does not accept stays as typed.
        func canonical(_ text: String) -> String {
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch kind {
            case .text: return s
            case .number: return Self.number(s).map { $0 > 0 ? String($0) : "" } ?? s
            case .date: return s.isEmpty ? "" : ReleaseDate(s)?.isoString ?? s
            case .isrc: return Self.normalizedISRC(s)
            }
        }

        /// 0...9999 from plain digits.
        static func number(_ s: String) -> Int? {
            if s.isEmpty { return 0 }
            guard s.utf8.count <= 4, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            return Int(s)
        }

        static func normalizedISRC(_ s: String) -> String {
            s.uppercased().filter { $0 != "-" && $0 != " " }
        }

        /// CC-XXX-YY-NNNNN: country, registrant, year, designation.
        static func isISRC(_ s: String) -> Bool {
            let chars = Array(s.utf8)
            guard chars.count == 12 else { return false }
            func letter(_ c: UInt8) -> Bool { c >= 0x41 && c <= 0x5A }
            func digit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
            return chars[0..<2].allSatisfy(letter) && chars[2..<5].allSatisfy { letter($0) || digit($0) }
                && chars[5..<12].allSatisfy(digit)
        }
    }

    /// A checkbox that may be on for some tracks only.
    public enum TriState: Sendable, Hashable { case off, on, mixed }

    /// A change to the embedded front cover.
    public enum CoverEdit: Sendable, Hashable {
        case set(Data)
        case remove
    }
}
