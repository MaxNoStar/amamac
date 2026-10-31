import Foundation
import GRDB

/// A dynamic playlist rule (Amarok's "biases"). Biases form a tree; each node narrows which
/// collection tracks may come next.
public indirect enum Bias: Codable, Sendable, Equatable, Hashable {
    /// Any track.
    case random
    /// Tracks matching every child.
    case and([Bias])
    /// Tracks matching any child.
    case or([Bias])
    /// Tracks not matching the child.
    case not(Bias)
    /// Children chosen in proportion to their weights.
    case partition([WeightedBias])
    /// The first child that matches any track.
    case ifElse([Bias])
    /// Tracks matching a collection filter (same syntax as the collection search).
    case search(String)
    /// Keeps albums together, relative to the previous track.
    case albumPlay(AlbumPlayMode)
    /// The first letter of a field must equal the last letter of the previous track's field.
    case quizPlay(QuizField)

    public enum AlbumPlayMode: String, Codable, Sendable, CaseIterable, Hashable {
        case directlyFollows, follows, sameAlbum
        public var displayName: String {
            switch self {
            case .directlyFollows: "Track directly follows the previous track in the album"
            case .follows: "Track comes after the previous track in the album"
            case .sameAlbum: "Track is from the same album as the previous track"
            }
        }

        public var shortName: String {
            switch self {
            case .directlyFollows: "next track"
            case .follows: "a later track"
            case .sameAlbum: "same album"
            }
        }
    }

    public enum QuizField: String, Codable, Sendable, CaseIterable, Hashable {
        case title, artist, album
    }

    public struct WeightedBias: Codable, Sendable, Equatable, Hashable {
        public var weight: Double
        public var bias: Bias
        public init(weight: Double, bias: Bias) {
            self.weight = weight
            self.bias = bias
        }
    }

    public var displayName: String {
        switch self {
        case .random: "Random"
        case .and: "Match all"
        case .or: "Match any"
        case .not: "Not"
        case .partition: "Partition"
        case .ifElse: "If / Else"
        case .search(let q): "Search: \(q)"
        case .albumPlay(let mode): "Album play (\(mode.rawValue))"
        case .quizPlay(let field): "Quiz play (\(field.rawValue))"
        }
    }

    /// One line describing the whole tree, e.g. `“genre:rock” or “genre:pop”`.
    public var summary: String {
        switch self {
        case .random: return "Random"
        case .and(let c): return c.isEmpty ? "Any track" : c.map(\.nestedSummary).joined(separator: " and ")
        case .or(let c): return c.isEmpty ? "Any track" : c.map(\.nestedSummary).joined(separator: " or ")
        case .not(let b): return "not " + b.nestedSummary
        case .partition(let parts):
            let total = parts.reduce(0) { $0 + max(0, $1.weight) }
            return parts.map { "\(total > 0 ? Int((max(0, $0.weight) / total * 100).rounded()) : 0)% \($0.bias.nestedSummary)" }
                .joined(separator: " + ")
        case .ifElse(let c): return c.map(\.nestedSummary).joined(separator: ", else ")
        case .search(let q): return q.isEmpty ? "Any track" : "“\(q)”"
        case .albumPlay(let mode): return "Album play: \(mode.shortName)"
        case .quizPlay(let field): return "Quiz play on \(field.rawValue)"
        }
    }

    private var nestedSummary: String {
        switch self {
        case .and, .or, .partition, .ifElse: "(\(summary))"
        default: summary
        }
    }

    public var children: [Bias] {
        switch self {
        case .and(let c), .or(let c), .ifElse(let c): c
        case .not(let b): [b]
        case .partition(let parts): parts.map(\.bias)
        default: []
        }
    }

    /// Every search query in the tree (evaluated up front with SQL).
    public var searchQueries: Set<String> {
        if case .search(let q) = self { return [q] }
        return children.reduce(into: Set<String>()) { $0.formUnion($1.searchQueries) }
    }
}
