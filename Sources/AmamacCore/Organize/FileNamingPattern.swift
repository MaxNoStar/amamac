import Foundation

/// Options for "Organize Files".
public struct OrganizeOptions: Sendable, Equatable, Codable {
    public var replaceSpaces = false
    /// Moves a leading "The" to the end for `%artist%` / `%albumartist%` ("Beatles, The").
    public var ignoreThe = true
    public var vfatSafe = true
    public var asciiOnly = false
    public var regexFind = ""
    public var regexReplace = ""
    public var overwrite = false

    public init() {}
}

/// Expands Organize Files patterns such as `%artist%/%album%/%track% - %title%`.
/// `{...}` marks an optional section that disappears when any token inside it is empty.
public struct FileNamingPattern: Sendable, Equatable {
    public static let defaultScheme = "%albumartist%/%album%{ (%year%)}/{%discnumber%-}{%track% - }%title%"
    public static let presets: [(name: String, pattern: String)] = [
        ("Album Artist/Album/Track - Title", defaultScheme),
        ("Artist/Album/Track_-_Title", "%artist%/%album%/%track%_-_%title%"),
        ("Initial/Artist/Album/Track - Title", "%initial%/%albumartist%/%album%/%track% - %title%"),
        ("Genre/Artist/Album/Track - Title", "%genre%/%albumartist%/%album%/%track% - %title%"),
    ]
    public static let tokens = ["%title%", "%artist%", "%theartist%", "%albumartist%", "%thealbumartist%",
                                "%album%", "%genre%", "%composer%", "%comment%", "%year%", "%track%",
                                "%discnumber%", "%folder%", "%filetype%", "%initial%", "%collectionroot%"]

    public var pattern: String
    public init(_ pattern: String) { self.pattern = pattern }

    /// Returns the destination path (with extension) for `track` under `collectionRoot`.
    public func destination(for track: Track, collectionRoot: String, options: OrganizeOptions) -> String {
        var relative = render(track: track, collectionRoot: collectionRoot, options: options)
        let ext = (track.path as NSString).pathExtension
        if !ext.isEmpty { relative += "." + ext.lowercased() }
        if relative.hasPrefix("/") { return relative }
        return (collectionRoot as NSString).appendingPathComponent(relative)
    }

    public func render(track: Track, collectionRoot: String, options: OrganizeOptions) -> String {
        let values = tokenValues(track: track, collectionRoot: collectionRoot, options: options)
        let expanded = expand(pattern, values: values)
        // Clean each path component separately so separators in the pattern survive.
        let components = expanded.split(separator: "/", omittingEmptySubsequences: false).enumerated().map { index, part -> String in
            let s = String(part)
            if index == 0 && s.isEmpty { return "" } // absolute path from %collectionroot%
            return clean(s, options: options)
        }
        return components.enumerated().filter { $0.offset == 0 || !$0.element.isEmpty }.map(\.element).joined(separator: "/")
    }

    func tokenValues(track t: Track, collectionRoot: String, options: OrganizeOptions) -> [String: String] {
        func theMoved(_ s: String) -> String {
            guard options.ignoreThe, s.lowercased().hasPrefix("the "), s.count > 4 else { return s }
            return String(s.dropFirst(4)) + ", " + String(s.prefix(3))
        }
        func safe(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "-") }
        let artist = t.artist.isEmpty ? TrackText.unknownArtist : t.artist
        let albumArtist = t.compilation ? TrackText.variousArtists : (t.albumArtist.isEmpty ? artist : t.albumArtist)
        let initialSource = theMoved(albumArtist)
        let initial = initialSource.first.map { String($0).uppercased() } ?? ""
        return [
            "title": safe(t.displayTitle),
            "artist": safe(theMoved(artist)),
            "theartist": safe(artist),
            "albumartist": safe(theMoved(albumArtist)),
            "thealbumartist": safe(albumArtist),
            "album": safe(t.album.isEmpty ? TrackText.unknownAlbum : t.album),
            "genre": safe(t.genre),
            "composer": safe(t.composer),
            "comment": safe(t.comment),
            "year": t.year > 0 ? String(t.year) : "",
            "track": t.trackNumber > 0 ? String(format: "%02d", t.trackNumber) : "",
            "discnumber": t.discNumber > 0 ? String(t.discNumber) : "",
            "folder": safe((t.directory as NSString).lastPathComponent),
            "filetype": (t.path as NSString).pathExtension.lowercased(),
            "initial": initial,
            "collectionroot": collectionRoot,
        ]
    }

    /// Expands tokens, dropping `{...}` sections that contain an empty token.
    func expand(_ pattern: String, values: [String: String]) -> String {
        var output = ""
        var section: String?
        var sectionEmpty = false
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let ch = pattern[i]
            if ch == "{" {
                section = ""
                sectionEmpty = false
                i = pattern.index(after: i)
                continue
            }
            if ch == "}", let s = section {
                if !sectionEmpty { output += s }
                section = nil
                i = pattern.index(after: i)
                continue
            }
            if ch == "%", let close = pattern[pattern.index(after: i)...].firstIndex(of: "%") {
                let name = String(pattern[pattern.index(after: i)..<close]).lowercased()
                if let value = values[name] {
                    if value.isEmpty { sectionEmpty = true }
                    if section != nil { section! += value } else { output += value }
                    i = pattern.index(after: close)
                    continue
                }
            }
            if section != nil { section!.append(ch) } else { output.append(ch) }
            i = pattern.index(after: i)
        }
        if let s = section, !sectionEmpty { output += s }
        return output
    }

    func clean(_ component: String, options: OrganizeOptions) -> String {
        var s = component
        if !options.regexFind.isEmpty, let regex = try? NSRegularExpression(pattern: options.regexFind) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: options.regexReplace)
        }
        if options.asciiOnly {
            s = s.applyingTransform(.toLatin, reverse: false) ?? s
            s = s.folding(options: [.diacriticInsensitive], locale: nil)
            s = String(s.unicodeScalars.filter { $0.isASCII }.map(Character.init))
        }
        if options.vfatSafe {
            let illegal = CharacterSet(charactersIn: "\\:*?\"<>|")
            s = String(s.unicodeScalars.map { illegal.contains($0) ? "_" : Character($0) })
            while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        }
        if options.replaceSpaces { s = s.replacingOccurrences(of: " ", with: "_") }
        if s.hasPrefix(".") { s = "_" + s.dropFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
