import Testing
@testable import AmamacModels

struct ReleaseDateTests {
    @Test(arguments: [
        ("1998", "1998", ReleaseDate.Precision.year),
        ("1998-03", "1998-03", .month),
        ("1998-03-12", "1998-03-12", .day),
        ("  1998-3-2 ", "1998-03-02", .day),
        ("1998-03-12T08:00:00Z", "1998-03-12", .day),
        ("1998-03-12T23:30:00-05:00", "1998-03-12", .day),
        ("1998-03-12 08:00", "1998-03-12", .day),
        ("1998-03-12T08:00:00.250+0100", "1998-03-12", .day),
        ("12/03/1998", "1998-03-12", .day),
        ("03/25/1998", "1998-03-25", .day),
        ("12.03.1998", "1998-03-12", .day),
        ("1998/03/12", "1998-03-12", .day),
        ("03/1998", "1998-03", .month),
        ("1998-00-00", "1998", .year),
        ("1998-05-00", "1998-05", .month),
        ("2000-02-29", "2000-02-29", .day),
    ])
    func parses(text: String, iso: String, precision: ReleaseDate.Precision) throws {
        let date = try #require(ReleaseDate(text))
        #expect(date.isoString == iso)
        #expect(date.precision == precision)
        #expect(date.year == Int(iso.prefix(4)))
    }

    @Test(arguments: ["", "abc", "98", "0000", "19980312", "1998-13", "1998-02-30", "1900-02-29", "1998-03-12T25",
                      "1998T08:00", "1998-03-12Tnoon", "13/13/1998", "1998 (remaster)", "-1998", "1998--03"])
    func rejects(text: String) {
        #expect(ReleaseDate(text) == nil)
    }

    /// Amamac 0.1.6 and earlier stored year-only ID3 dates as July 1st, noon UTC.
    @Test func legacyTimestampIsAYear() throws {
        let date = try #require(ReleaseDate("1987-07-01T12:00:00Z"))
        #expect(date.isoString == "1987")
        #expect(date.precision == .year)
        #expect(ReleaseDate("1987-07-01T12:00:01Z")?.isoString == "1987-07-01")
    }

    @Test func lenientParsingFindsAYear() {
        #expect(ReleaseDate.lenient("Spring 1998")?.isoString == "1998")
        #expect(ReleaseDate.lenient("1998 (remaster)")?.isoString == "1998")
        #expect(ReleaseDate.lenient("1998-03-12")?.isoString == "1998-03-12")
        #expect(ReleaseDate.lenient("c. 12345") == nil)
        #expect(ReleaseDate.lenient(nil) == nil)
    }

    @Test func ordersByDateThenPrecision() throws {
        let dates = try ["1999", "1998-01-02", "1998", "1998-01"].map { try #require(ReleaseDate($0)) }
        #expect(dates.sorted().map(\.isoString) == ["1998", "1998-01", "1998-01-02", "1999"])
    }

    /// `year` follows the release date; a track built from a year alone gets it as its date.
    @Test func trackYearFollowsTheDate() {
        var t = Track(path: "/x.flac", year: 1970)
        t.updateDerivedFields()
        #expect(t.releaseDate == "1970")
        t.releaseDate = "1998-03-12"
        t.updateDerivedFields()
        #expect(t.year == 1998)
    }
}
