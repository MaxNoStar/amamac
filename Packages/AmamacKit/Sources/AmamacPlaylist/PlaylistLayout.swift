import Foundation

/// One element of a playlist layout line (Amarok's layout "tokens").
public struct LayoutToken: Sendable, Codable, Hashable {
    public enum Alignment: String, Sendable, Codable { case left, center, right }

    public var column: PlaylistColumn
    /// Fraction of the line width (0...1); 0 means "share the remaining space".
    public var width: Double
    public var alignment: Alignment
    public var bold: Bool
    public var italic: Bool
    public var prefix: String
    public var suffix: String

    public init(_ column: PlaylistColumn, width: Double = 0, alignment: Alignment = .left, bold: Bool = false,
                italic: Bool = false, prefix: String = "", suffix: String = "") {
        self.column = column
        self.width = width
        self.alignment = alignment
        self.bold = bold
        self.italic = italic
        self.prefix = prefix
        self.suffix = suffix
    }
}

public typealias LayoutLine = [LayoutToken]

/// A playlist layout: how group heads, group bodies and single tracks are drawn.
public struct PlaylistLayout: Sendable, Codable, Hashable, Identifiable {
    public var name: String
    public var head: [LayoutLine]
    public var body: [LayoutLine]
    /// Used for tracks that form a group of one (and for every row when grouping is off).
    public var single: [LayoutLine]
    public var showCover: Bool
    public var grouping: PlaylistGrouping
    public var isBuiltIn: Bool

    public var id: String { name }

    public init(name: String, head: [LayoutLine], body: [LayoutLine], single: [LayoutLine], showCover: Bool,
                grouping: PlaylistGrouping, isBuiltIn: Bool = false) {
        self.name = name
        self.head = head
        self.body = body
        self.single = single
        self.showCover = showCover
        self.grouping = grouping
        self.isBuiltIn = isBuiltIn
    }

    public static let `default` = PlaylistLayout(
        name: "Default",
        head: [[LayoutToken(.album, alignment: .center, bold: true)],
               [LayoutToken(.albumArtist, alignment: .center, bold: true, italic: true)]],
        body: [[LayoutToken(.titleWithTrackNumber, width: 0.8), LayoutToken(.length, width: 0.2, alignment: .right)]],
        single: [[LayoutToken(.title, width: 0.8, bold: true), LayoutToken(.length, width: 0.2, alignment: .right)],
                 [LayoutToken(.artist, width: 0.5, italic: true), LayoutToken(.album, width: 0.5, alignment: .right)]],
        showCover: true, grouping: .album, isBuiltIn: true)

    public static let noGrouping = PlaylistLayout(
        name: "No Grouping",
        head: [], body: [],
        single: [[LayoutToken(.title, width: 0.8, bold: true), LayoutToken(.length, width: 0.2, alignment: .right)],
                 [LayoutToken(.artist, width: 0.5, italic: true), LayoutToken(.album, width: 0.5, alignment: .right)]],
        showCover: true, grouping: .none, isBuiltIn: true)

    public static let noGroupingSingleLine = PlaylistLayout(
        name: "No Grouping (Single Line)",
        head: [], body: [],
        single: [[LayoutToken(.title, width: 0.45, bold: true), LayoutToken(.artist, width: 0.4, italic: true),
                  LayoutToken(.length, width: 0.15, alignment: .right)]],
        showCover: false, grouping: .none, isBuiltIn: true)

    public static let verbose = PlaylistLayout(
        name: "Verbose",
        head: [[LayoutToken(.album, alignment: .center, bold: true)],
               [LayoutToken(.albumArtist, alignment: .center, bold: true, italic: true)],
               [LayoutToken(.year, width: 0.2), LayoutToken(.genre, width: 0.3), LayoutToken(.type, width: 0.2),
                LayoutToken(.groupTracks, width: 0.15, alignment: .right, suffix: " tracks"),
                LayoutToken(.groupLength, width: 0.15, alignment: .right)]],
        body: [[LayoutToken(.titleWithTrackNumber, width: 0.6), LayoutToken(.rating, width: 0.2, alignment: .center),
                LayoutToken(.length, width: 0.2, alignment: .right)]],
        single: [[LayoutToken(.title, width: 0.6, bold: true), LayoutToken(.rating, width: 0.2, alignment: .center),
                  LayoutToken(.length, width: 0.2, alignment: .right)],
                 [LayoutToken(.artist, width: 0.5, italic: true), LayoutToken(.album, width: 0.5, alignment: .right)]],
        showCover: true, grouping: .album, isBuiltIn: true)

    public static let builtIn: [PlaylistLayout] = [.default, .noGrouping, .noGroupingSingleLine, .verbose]
}
