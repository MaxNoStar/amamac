import Foundation
import GRDB
import Testing
@testable import AmamacDatabase
@testable import AmamacModels
@testable import AmamacQuery

struct QueryParsingTests {
    @Test func freeTextAndFields() {
        let q = CollectionQuery.parse("beatles album:\"abbey road\" -genre:pop")
        #expect(q.groups.count == 3)
        #expect(q.groups[0] == [QueryTerm(value: "beatles")])
        #expect(q.groups[1] == [QueryTerm(field: .album, value: "abbey road")])
        #expect(q.groups[2] == [QueryTerm(negated: true, field: .genre, value: "pop")])
    }

    @Test func orBindsNeighboursLikeAmarok() {
        let q = CollectionQuery.parse("a b OR c d")
        #expect(q.groups.map { $0.map(\.value) } == [["a"], ["b", "c"], ["d"]])
    }

    @Test func operatorsAndAliases() {
        let q = CollectionQuery.parse("rating:>3.5 played:<2w codec:flac year:=1999")
        #expect(q.groups[0][0] == QueryTerm(field: .rating, op: .greater, value: "3.5"))
        #expect(q.groups[1][0] == QueryTerm(field: .lastplay, op: .less, value: "2w"))
        #expect(q.groups[2][0].field == .format)
        #expect(q.groups[3][0] == QueryTerm(field: .year, op: .equals, value: "1999"))
    }

    @Test func unknownFieldIsFreeText() {
        let q = CollectionQuery.parse("12:30 foo:bar")
        #expect(q.groups[0][0].field == nil)
        #expect(q.groups[1][0] == QueryTerm(value: "foo:bar"))
    }

    @Test func roundTripsText() {
        let text = "artist:\"pink floyd\" -genre:pop year:>1970"
        #expect(CollectionQuery.parse(CollectionQuery.parse(text).text) == CollectionQuery.parse(text))
    }

    @Test func relativeDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        guard case .relative(let d) = QueryDateValue.parse("2w", now: now, calendar: cal) else { Issue.record("not relative"); return }
        #expect(abs(now.timeIntervalSince(d) - 14 * 86_400) < 1)
        guard case .relative(let e) = QueryDateValue.parse("1y2m", now: now, calendar: cal) else { Issue.record("not relative"); return }
        #expect(e < d)
        #expect(QueryDateValue.parse("2x", now: now) == nil)
        guard case .day = QueryDateValue.parse("1.2.2020", now: now) else { Issue.record("not a day"); return }
    }
}

struct QueryMatchingTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func track() -> (Track, TrackStatistics) {
        var t = makeTrack("Come Together", artist: "The Beatles", album: "Abbey Road", track: 1, year: 1969, genre: "Rock",
                          durationMs: 259_000)
        t.dateAdded = now.addingTimeInterval(-3 * 86_400)
        let s = TrackStatistics(trackId: 1, rating: 8, score: 75, playCount: 12,
                                firstPlayed: now.addingTimeInterval(-400 * 86_400), lastPlayed: now.addingTimeInterval(-86_400))
        return (t, s)
    }

    func matches(_ q: String) -> Bool {
        let (t, s) = track()
        return CollectionQuery.parse(q).matches(t, statistics: s, labels: ["favourite"], now: now)
    }

    @Test(arguments: [
        ("beatles", true), ("BEATLES", true), ("abbey", true), ("1969", true), ("favourite", true), ("zeppelin", false),
        ("artist:beatles", true), ("artist:=the beatles", false), ("artist:=\"the beatles\"", true),
        ("album:road -genre:jazz", true), ("-artist:beatles", false),
        ("year:>1960", true), ("year:<1960", false), ("year:1969", true),
        ("rating:4", true), ("rating:>4", false), ("rating:>3.5", true),
        ("length:>4:00", true), ("length:<200", false),
        ("playcount:>10", true), ("score:>80", false),
        ("added:<1w", true), ("added:>1w", false), ("lastplay:<2d", true), ("firstplay:<1y", false),
        ("label:fav", true), ("jazz OR beatles", true), ("jazz OR blues", false),
    ])
    func evaluates(query: String, expected: Bool) {
        #expect(matches(query) == expected, "\(query)")
    }

    @Test func diacriticsAreFolded() {
        let t = makeTrack("Jóga", artist: "Björk")
        #expect(CollectionQuery.parse("bjork joga").matches(t, statistics: nil))
    }
}

struct QuerySQLTests {
    @Test func sqlAgreesWithInMemoryMatching() throws {
        let db = try LibraryDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var tracks = [
            makeTrack("Come Together", artist: "The Beatles", album: "Abbey Road", year: 1969, durationMs: 259_000),
            makeTrack("Jóga", artist: "Björk", album: "Homogenic", year: 1997, genre: "Electronic", durationMs: 305_000),
            makeTrack("So What", artist: "Miles Davis", album: "Kind of Blue", year: 1959, genre: "Jazz", durationMs: 562_000),
        ]
        try db.writer.write { db in
            for i in tracks.indices {
                tracks[i].dateAdded = now.addingTimeInterval(Double(-i) * 10 * 86_400)
                try tracks[i].insert(db)
            }
            try TrackStatistics(trackId: tracks[0].id!, rating: 10, score: 90, playCount: 5, lastPlayed: now).insert(db)
            try CollectionQueries.setLabels(db, trackId: tracks[2].id!, labels: ["Chill"])
        }
        let queries = ["beatles", "bjork", "-genre:jazz", "year:<1970", "rating:5", "rating:>4", "length:>5:00",
                       "label:chill", "chill", "added:<5d", "added:>15d", "genre:rock OR genre:jazz", "playcount:0",
                       "album:\"kind of\"", "lastplay:<1d", "format:flac"]
        for q in queries {
            let query = CollectionQuery.parse(q)
            let sqlCount = try db.writer.read { try CollectionQueries.count($0, filter: query, now: now) }
            let memCount = try tracks.filter { t in
                let s = try db.writer.read { try CollectionQueries.statistics($0, trackId: t.id!) }
                let labels = try db.writer.read { try CollectionQueries.labels($0, trackId: t.id!) }
                return query.matches(t, statistics: s, labels: labels, now: now)
            }.count
            #expect(sqlCount == memCount, "\(q): sql \(sqlCount) vs memory \(memCount)")
        }
    }
}
