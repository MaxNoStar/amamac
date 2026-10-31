import Foundation

/// A named dynamic playlist definition.
public struct DynamicPlaylist: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: Int64?
    public var name: String
    public var bias: Bias

    public init(id: Int64? = nil, name: String, bias: Bias) {
        self.id = id
        self.name = name
        self.bias = bias
    }

    public static let presets: [DynamicPlaylist] = [
        DynamicPlaylist(name: "Random", bias: .random),
        DynamicPlaylist(name: "Rock and Pop", bias: .or([.search("genre:rock"), .search("genre:pop")])),
        DynamicPlaylist(name: "Album Play", bias: .albumPlay(.directlyFollows)),
        DynamicPlaylist(name: "Highly Rated", bias: .partition([.init(weight: 2, bias: .search("rating:>3")), .init(weight: 1, bias: .random)])),
        DynamicPlaylist(name: "Quiz Play", bias: .quizPlay(.artist)),
        DynamicPlaylist(name: "Never Played", bias: .ifElse([.search("playcount:0"), .random])),
    ]
}
