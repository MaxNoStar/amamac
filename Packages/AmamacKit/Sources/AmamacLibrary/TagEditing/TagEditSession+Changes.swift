import AmamacModels
import Foundation

extension TagEditSession {
    // MARK: Tools

    /// Number Tracks: 1…N per disc over every open track (see `TrackNumbering`), with N as "of N".
    public mutating func numberTracks() {
        let inputs = tracks.indices.map { i in
            TrackNumbering.Input(discNumber: Field.number(Field.discNumber.canonical(current[i].discNumber)) ?? 0,
                                 trackNumber: Field.number(Field.trackNumber.canonical(current[i].trackNumber)) ?? 0,
                                 fileName: tracks[i].fileName)
        }
        for (i, number) in TrackNumbering.number(inputs).enumerated() {
            current[i].trackNumber = String(number.trackNumber)
            current[i].trackTotal = String(number.trackTotal)
        }
    }

    /// Guess from Filename for the edited tracks; returns how many file names matched.
    @discardableResult
    public mutating func guessFromFilenames(pattern: String) -> Int {
        let fields: [String: Field] = ["title": .title, "artist": .artist, "albumartist": .albumArtist, "album": .album,
                                       "genre": .genre, "composer": .composer, "comment": .comment, "track": .trackNumber,
                                       "discnumber": .discNumber, "year": .releaseDate]
        var matched = 0
        for i in targets {
            guard let guess = FilenameTagGuesser.guess(path: tracks[i].path, pattern: pattern) else { continue }
            matched += 1
            for (token, value) in guess {
                if let field = fields[token] { current[i][field] = value }
            }
        }
        return matched
    }

    /// Fills one track's fields (a MusicBrainz match); empty values are skipped.
    public mutating func fill(_ values: [Field: String], at i: Int) {
        guard current.indices.contains(i) else { return }
        for (field, value) in values where !value.isEmpty { current[i][field] = value }
    }

    // MARK: Changes

    /// What to write to track `i`'s file. Play counts never go to files.
    public func changes(at i: Int) -> TagChanges {
        var c = TagChanges()
        let a = original[i], b = current[i]
        func changed(_ field: Field) -> String? {
            let new = field.canonical(b[field])
            return field.canonical(a[field]) == new ? nil : new
        }
        func number(_ field: Field) -> Int? {
            changed(field).flatMap { Field.number($0) }
        }
        c.title = changed(.title)
        c.artist = changed(.artist)
        c.albumArtist = changed(.albumArtist)
        c.album = changed(.album)
        c.composer = changed(.composer)
        c.genre = changed(.genre)
        c.comment = changed(.comment)
        c.trackNumber = number(.trackNumber)
        c.trackTotal = number(.trackTotal)
        c.discNumber = number(.discNumber)
        c.discTotal = number(.discTotal)
        c.bpm = number(.bpm)
        c.releaseDate = changed(.releaseDate)
        c.originalDate = changed(.originalDate)
        c.grouping = changed(.grouping)
        c.isrc = changed(.isrc)
        c.titleSort = changed(.titleSort)
        c.artistSort = changed(.artistSort)
        c.albumArtistSort = changed(.albumArtistSort)
        c.albumSort = changed(.albumSort)
        if a.compilation != b.compilation { c.compilation = b.compilation }
        switch covers[i] {
        case .set(let data): c.frontCover = data
        case .remove: c.frontCover = Data()
        case nil: break
        }
        return c
    }

    /// File writes for every track with changes.
    public var edits: [TrackEditor.Edit] {
        tracks.indices.compactMap { i in
            let c = changes(at: i)
            return c.isEmpty ? nil : TrackEditor.Edit(path: tracks[i].path, changes: c)
        }
    }

    /// Collection tracks whose labels changed, with their new labels.
    public var labelEdits: [(trackId: Int64, labels: [String])] {
        tracks.indices.compactMap { i in
            guard labels[i] != originalLabels[i], let id = tracks[i].id else { return nil }
            return (id, labels[i].sorted())
        }
    }

    /// Collection tracks whose play count changed (library only).
    public var playCountEdits: [(trackId: Int64, playCount: Int)] {
        tracks.indices.compactMap { i in
            guard playCounts[i] != originalPlayCounts[i], let id = tracks[i].id else { return nil }
            return (id, playCounts[i])
        }
    }

    /// Whether the cover of any track changes.
    public var changesCovers: Bool { covers.contains { $0 != nil } }

    public var hasChanges: Bool {
        !edits.isEmpty || !labelEdits.isEmpty || !playCountEdits.isEmpty
    }

    /// Something changed and every changed value can be written.
    public var canSave: Bool { hasChanges && invalidFields.isEmpty }
}
