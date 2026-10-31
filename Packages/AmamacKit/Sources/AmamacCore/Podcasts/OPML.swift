import Foundation

public enum OPML {
    public struct Outline: Sendable, Equatable {
        public var title: String
        public var feedURL: URL
        public init(title: String, feedURL: URL) {
            self.title = title
            self.feedURL = feedURL
        }
    }

    /// Every outline with an `xmlUrl`, however deeply nested.
    public static func parse(_ data: Data) throws -> [Outline] {
        final class Delegate: NSObject, XMLParserDelegate {
            var outlines: [Outline] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String] = [:]) {
                guard name.lowercased() == "outline", let raw = attributes["xmlUrl"] ?? attributes["xmlurl"],
                      let url = URL(string: raw.trimmingCharacters(in: .whitespaces)) else { return }
                outlines.append(Outline(title: attributes["title"] ?? attributes["text"] ?? url.absoluteString, feedURL: url))
            }
        }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? PodcastFeedError.notAFeed }
        return delegate.outlines
    }

    public static func export(_ outlines: [Outline], title: String) -> Data {
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <head><title>\(XMLText.escape(title))</title></head>
              <body>

            """
        for o in outlines {
            xml += "    <outline type=\"rss\" text=\"\(XMLText.escape(o.title))\" title=\"\(XMLText.escape(o.title))\" xmlUrl=\"\(XMLText.escape(o.feedURL.absoluteString))\"/>\n"
        }
        xml += "  </body>\n</opml>\n"
        return Data(xml.utf8)
    }
}
