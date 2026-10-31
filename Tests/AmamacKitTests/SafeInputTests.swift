import Foundation
import Testing
@testable import AmamacBase

/// The AmamacBase helpers that keep outside data (tags, feeds, playlists, links, headers) from
/// crashing the app or escaping into paths and file formats.
struct SafeInputTests {
    @Test func durationsThatWouldTrapBecomeNil() {
        #expect(SafeNumbers.milliseconds(seconds: 2.5) == 2500)
        #expect(SafeNumbers.milliseconds(seconds: 0.0) == 0)
        for bad in [Double.nan, .infinity, -.infinity, -1, 1e300, SafeNumbers.maxSeconds] {
            #expect(SafeNumbers.milliseconds(seconds: bad) == nil)
        }
        #expect(SafeNumbers.milliseconds(seconds: 245) == 245_000)
        #expect(SafeNumbers.milliseconds(seconds: Int.max) == nil)
        #expect(SafeNumbers.milliseconds(seconds: 9_223_372_036_854_775) == nil)
        #expect(SafeNumbers.milliseconds(seconds: -5) == nil)
        #expect(SafeNumbers.int(44_100.0) == 44_100)
        #expect(SafeNumbers.int(.nan) == nil)
        #expect(SafeNumbers.int(1e20) == nil)
        #expect(SafeNumbers.int(-1) == nil)
    }

    @Test func pathComponentsCannotHideSeparatorsOrClimbUp() {
        // A combining mark after "/" makes one Character, which character-based replacing misses.
        #expect(PathComponent.withoutSeparators("x/\u{301}../\u{301}..") == "x-\u{301}..-\u{301}..")
        #expect(!PathComponent.withoutSeparators("a/\u{200D}b").unicodeScalars.contains("/"))
        #expect(PathComponent.withoutSeparators("a\u{0}b\nc\td") == "abcd")
        #expect(PathComponent.sanitized("..") == "_.")
        #expect(PathComponent.sanitized(".") == "_")
        #expect(PathComponent.sanitized(".hidden") == "_hidden")
        #expect(PathComponent.sanitized("  ") == "_")
        #expect(PathComponent.sanitized(" AC/DC ") == "AC-DC")
        #expect(PathComponent.sanitized("Björk: Vespertine") == "Björk: Vespertine")
    }

    @Test func pathsCompareWholeComponents() {
        #expect(Paths.normalized("/Music/./a/../b//c/") == "/Music/b/c")
        #expect(Paths.normalized("/../../etc") == "/etc")
        #expect(Paths.isInside("/Music/Band/a.mp3", folder: "/Music"))
        #expect(Paths.isInside("/Music", folder: "/Music/"))
        #expect(!Paths.isInside("/Music Old/a.mp3", folder: "/Music"))
        #expect(!Paths.isInside("/Music/../Documents/a", folder: "/Music"))
    }

    @Test func onlyHttpAndHttpsAreWebURLs() {
        #expect(URL(string: "https://example.org")!.isWebURL)
        #expect(URL(string: "HTTP://example.org")!.isWebURL)
        for other in ["httpx://example.org", "file:///etc/passwd", "amamac://navigate", "javascript:alert(1)", "ftp://x"] {
            #expect(!URL(string: other)!.isWebURL, "\(other)")
        }
    }

    @Test func singleLineRemovesEveryKindOfBreak() {
        #expect("a\nb\r\nc\u{2028}d".singleLine == "a b  c d")
        #expect("plain".singleLine == "plain")
    }

    @Test func xmlEscapingDropsForbiddenCharacters() {
        #expect(XMLText.escape("a\u{0}b\u{1B}c\u{FFFE}") == "abc")
        #expect(XMLText.escape("tab\tline\nok") == "tab\tline\nok")
        #expect(XMLText.escape("<&\">") == "&lt;&amp;&quot;&gt;")
    }
}
