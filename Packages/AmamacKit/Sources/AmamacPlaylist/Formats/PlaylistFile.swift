import AmamacBase
import AmamacModels
import Foundation

/// An entry read from or written to a playlist file.
public struct PlaylistFileEntry: Sendable, Equatable {
    public var url: URL
    public var title: String?
    public var artist: String?
    public var album: String?
    public var durationMs: Int?
    public var trackNumber: Int?

    public init(url: URL, title: String? = nil, artist: String? = nil, album: String? = nil,
                durationMs: Int? = nil, trackNumber: Int? = nil) {
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.trackNumber = trackNumber
    }
}

public enum PlaylistFileError: Error, LocalizedError {
    case unsupportedFormat(String)
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): "Unsupported playlist format “\(ext)”."
        case .unreadable(let url): "Could not read “\(url.lastPathComponent)”."
        }
    }
}

public enum PlaylistFile {
    // MARK: Reading

    public static func read(from url: URL) throws -> [PlaylistFileEntry] {
        guard let format = PlaylistFileFormat.from(url: url) else {
            throw PlaylistFileError.unsupportedFormat(url.pathExtension)
        }
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let base = url.deletingLastPathComponent()
        switch format {
        case .m3u, .m3u8: return parseM3U(text, base: base)
        case .pls: return parsePLS(text, base: base)
        case .xspf: return parseXSPF(data, base: base)
        case .asx: return parseASX(text, base: base)
        }
    }

    /// Resolves a playlist location: absolute URL, absolute path, `file://` URL or a path relative
    /// to the playlist file.
    public static func resolve(_ location: String, base: URL) -> URL? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme, scheme.count > 1 {
            return url.isFileURL ? url.standardizedFileURL : url
        }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed).standardizedFileURL }
        if trimmed.hasPrefix("~") { return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath) }
        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        return URL(fileURLWithPath: (base.path as NSString).appendingPathComponent(normalized)).standardizedFileURL
    }

    public static func parseM3U(_ text: String, base: URL) -> [PlaylistFileEntry] {
        var entries: [PlaylistFileEntry] = []
        var pendingTitle: String?
        var pendingArtist: String?
        var pendingDuration: Int?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF:") {
                let info = line.dropFirst("#EXTINF:".count)
                if let comma = info.firstIndex(of: ",") {
                    let seconds = Int(info[..<comma].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? -1
                    pendingDuration = seconds > 0 ? seconds * 1000 : nil
                    let label = String(info[info.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                    if let dash = label.range(of: " - ") {
                        pendingArtist = String(label[..<dash.lowerBound])
                        pendingTitle = String(label[dash.upperBound...])
                    } else {
                        pendingTitle = label.isEmpty ? nil : label
                    }
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            if let url = resolve(line, base: base) {
                entries.append(PlaylistFileEntry(url: url, title: pendingTitle, artist: pendingArtist, durationMs: pendingDuration))
            }
            pendingTitle = nil
            pendingArtist = nil
            pendingDuration = nil
        }
        return entries
    }

    public static func parsePLS(_ text: String, base: URL) -> [PlaylistFileEntry] {
        var files: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var lengths: [Int: Int] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].lowercased()
            let value = String(line[line.index(after: eq)...])
            func number(after prefix: String) -> Int? {
                key.hasPrefix(prefix) ? Int(key.dropFirst(prefix.count)) : nil
            }
            if let n = number(after: "file") { files[n] = value }
            else if let n = number(after: "title") { titles[n] = value }
            else if let n = number(after: "length") { lengths[n] = Int(value) }
        }
        return files.keys.sorted().compactMap { n in
            guard let url = resolve(files[n]!, base: base) else { return nil }
            let length = lengths[n].flatMap { $0 > 0 ? $0 * 1000 : nil }
            return PlaylistFileEntry(url: url, title: titles[n], durationMs: length)
        }
    }

    public static func parseXSPF(_ data: Data, base: URL) -> [PlaylistFileEntry] {
        let parser = XSPFParser(base: base)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.entries
    }

    public static func parseASX(_ text: String, base: URL) -> [PlaylistFileEntry] {
        // ASX is loosely formed XML with case-insensitive tags; scan with regular expressions.
        var entries: [PlaylistFileEntry] = []
        let entryRegex = try! NSRegularExpression(pattern: "<entry[^>]*>(.*?)</entry>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        let refRegex = try! NSRegularExpression(pattern: "<ref\\s+href\\s*=\\s*\"([^\"]+)\"", options: [.caseInsensitive])
        let titleRegex = try! NSRegularExpression(pattern: "<title>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = text as NSString
        for match in entryRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: match.range(at: 1))
            let bns = body as NSString
            guard let ref = refRegex.firstMatch(in: body, range: NSRange(location: 0, length: bns.length)),
                  let url = resolve(unescapeXML(bns.substring(with: ref.range(at: 1))), base: base) else { continue }
            let title = titleRegex.firstMatch(in: body, range: NSRange(location: 0, length: bns.length))
                .map { unescapeXML(bns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)) }
            entries.append(PlaylistFileEntry(url: url, title: title))
        }
        return entries
    }

    // MARK: Writing

    public static func write(_ entries: [PlaylistFileEntry], to url: URL, format: PlaylistFileFormat? = nil,
                             relativePaths: Bool = true, title: String? = nil) throws {
        let format = format ?? PlaylistFileFormat.from(url: url) ?? .m3u8
        let base = url.deletingLastPathComponent()
        let text = serialize(entries, format: format, base: relativePaths ? base : nil, title: title)
        let encoding: String.Encoding = format == .m3u ? .isoLatin1 : .utf8
        guard let data = text.data(using: encoding, allowLossyConversion: true) else { return }
        try data.write(to: url, options: .atomic)
    }

    public static func serialize(_ entries: [PlaylistFileEntry], format: PlaylistFileFormat, base: URL?,
                                 title: String? = nil) -> String {
        func location(_ url: URL) -> String {
            guard url.isFileURL else { return url.absoluteString }
            if let base, let rel = relativePath(of: url, to: base) { return rel }
            return url.path
        }
        switch format {
        case .m3u, .m3u8:
            var lines = ["#EXTM3U"]
            for e in entries {
                let seconds = e.durationMs.map { $0 / 1000 } ?? -1
                let label = [e.artist, e.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
                if !label.isEmpty || seconds > 0 { lines.append("#EXTINF:\(seconds),\(label)") }
                lines.append(location(e.url))
            }
            return lines.joined(separator: "\n") + "\n"
        case .pls:
            var lines = ["[playlist]"]
            for (i, e) in entries.enumerated() {
                let n = i + 1
                lines.append("File\(n)=\(location(e.url))")
                if let t = e.title { lines.append("Title\(n)=\([e.artist, t].compactMap { $0 }.joined(separator: " - "))") }
                lines.append("Length\(n)=\(e.durationMs.map { $0 / 1000 } ?? -1)")
            }
            lines.append("NumberOfEntries=\(entries.count)")
            lines.append("Version=2")
            return lines.joined(separator: "\n") + "\n"
        case .xspf:
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<playlist version=\"1\" xmlns=\"http://xspf.org/ns/0/\">\n"
            if let title { xml += "  <title>\(XMLText.escape(title))</title>\n" }
            xml += "  <creator>\(Amamac.appName)</creator>\n  <trackList>\n"
            for e in entries {
                xml += "    <track>\n"
                let loc = e.url.isFileURL && base != nil ? location(e.url).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? location(e.url) : e.url.absoluteString
                xml += "      <location>\(XMLText.escape(loc))</location>\n"
                if let t = e.title { xml += "      <title>\(XMLText.escape(t))</title>\n" }
                if let a = e.artist { xml += "      <creator>\(XMLText.escape(a))</creator>\n" }
                if let a = e.album { xml += "      <album>\(XMLText.escape(a))</album>\n" }
                if let n = e.trackNumber, n > 0 { xml += "      <trackNum>\(n)</trackNum>\n" }
                if let d = e.durationMs, d > 0 { xml += "      <duration>\(d)</duration>\n" }
                xml += "    </track>\n"
            }
            xml += "  </trackList>\n</playlist>\n"
            return xml
        case .asx:
            var xml = "<asx version=\"3.0\">\n"
            if let title { xml += "  <title>\(XMLText.escape(title))</title>\n" }
            for e in entries {
                xml += "  <entry>\n"
                if let t = e.title { xml += "    <title>\(XMLText.escape(t))</title>\n" }
                if let a = e.artist { xml += "    <author>\(XMLText.escape(a))</author>\n" }
                xml += "    <ref href=\"\(XMLText.escape(e.url.isFileURL ? e.url.absoluteString : e.url.absoluteString))\"/>\n"
                xml += "  </entry>\n"
            }
            xml += "</asx>\n"
            return xml
        }
    }

    /// Path of `url` relative to `base` when it lives below it.
    static func relativePath(of url: URL, to base: URL) -> String? {
        let path = url.standardizedFileURL.path
        var basePath = base.standardizedFileURL.path
        if !basePath.hasSuffix("/") { basePath += "/" }
        guard path.hasPrefix(basePath) else { return nil }
        return String(path.dropFirst(basePath.count))
    }

    static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private final class XSPFParser: NSObject, XMLParserDelegate {
    let base: URL
    var entries: [PlaylistFileEntry] = []
    private var inTrack = false
    private var current: [String: String] = [:]
    private var text = ""

    init(base: URL) { self.base = base }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "track" {
            inTrack = true
            current = [:]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "track" {
            inTrack = false
            if let loc = current["location"] {
                let decoded = loc.hasPrefix("file:") || loc.contains("://") ? loc : (loc.removingPercentEncoding ?? loc)
                if let url = PlaylistFile.resolve(decoded, base: base) {
                    entries.append(PlaylistFileEntry(url: url, title: current["title"], artist: current["creator"],
                                                     album: current["album"], durationMs: current["duration"].flatMap { Int($0) },
                                                     trackNumber: current["trackNum"].flatMap { Int($0) }))
                }
            }
        } else if inTrack, current[elementName] == nil {
            current[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = ""
    }
}
