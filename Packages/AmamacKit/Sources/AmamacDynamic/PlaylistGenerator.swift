import AmamacBase
import Foundation

/// Automated Playlist Generator constraints (Amarok's APG). Constraints form a tree; groups
/// combine children with "all" or "any".
public indirect enum GeneratorConstraint: Codable, Sendable, Equatable, Hashable {
    case group(matchAll: Bool, [GeneratorConstraint])
    /// Tracks should match a collection filter (or not, when inverted).
    case matchTags(query: String, invert: Bool, strength: Double)
    case duration(seconds: Int, comparison: Comparison, strength: Double)
    case trackCount(Int, comparison: Comparison, strength: Double)
    case totalSize(megabytes: Int, comparison: Comparison, strength: Double)
    case preventDuplicates(DuplicateField)
    /// Tracks by the same artist should be at least three positions apart.
    case spreadArtists(strength: Double)
    /// A track matching `query` should start near `atSeconds` into the playlist.
    case checkpoint(query: String, atSeconds: Int, strength: Double)

    public enum Comparison: String, Codable, Sendable, CaseIterable, Hashable {
        case about, atLeast, atMost
        public var displayName: String {
            switch self {
            case .about: "about"
            case .atLeast: "at least"
            case .atMost: "at most"
            }
        }
    }

    public enum DuplicateField: String, Codable, Sendable, CaseIterable, Hashable { case track, artist, album }

    public var displayName: String {
        switch self {
        case .group(let all, _): all ? "Match all" : "Match any"
        case .matchTags(let q, let invert, _): (invert ? "Not matching: " : "Matching: ") + q
        case .duration(let s, let c, _): "Duration \(c.displayName) \(TimeFormatting.duration(TimeInterval(s)))"
        case .trackCount(let n, let c, _): "\(c.displayName.capitalized) \(n) tracks"
        case .totalSize(let mb, let c, _): "Size \(c.displayName) \(mb) MB"
        case .preventDuplicates(let f): "No duplicate \(f.rawValue)s"
        case .spreadArtists: "Spread out artists"
        case .checkpoint(let q, let t, _): "“\(q)” at \(TimeFormatting.duration(TimeInterval(t)))"
        }
    }

    public var searchQueries: Set<String> {
        switch self {
        case .group(_, let children): children.reduce(into: Set<String>()) { $0.formUnion($1.searchQueries) }
        case .matchTags(let q, _, _), .checkpoint(let q, _, _): [q]
        default: []
        }
    }
}

public struct GeneratorPreset: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: Int64?
    public var name: String
    public var root: GeneratorConstraint

    public init(id: Int64? = nil, name: String, root: GeneratorConstraint) {
        self.id = id
        self.name = name
        self.root = root
    }

    public static let presets: [GeneratorPreset] = [
        GeneratorPreset(name: "One Hour of Favourites", root: .group(matchAll: true, [
            .duration(seconds: 3600, comparison: .about, strength: 1),
            .matchTags(query: "rating:>3", invert: false, strength: 0.8),
            .preventDuplicates(.track),
            .spreadArtists(strength: 0.6),
        ])),
        GeneratorPreset(name: "20 Unplayed Tracks", root: .group(matchAll: true, [
            .trackCount(20, comparison: .about, strength: 1),
            .matchTags(query: "playcount:0", invert: false, strength: 1),
            .preventDuplicates(.track),
        ])),
        GeneratorPreset(name: "Fits on a CD", root: .group(matchAll: true, [
            .duration(seconds: 79 * 60, comparison: .atMost, strength: 1),
            .duration(seconds: 70 * 60, comparison: .atLeast, strength: 0.7),
            .preventDuplicates(.track),
        ])),
    ]
}

/// Solves generator constraints by simulated annealing over playlists drawn from the collection.
public struct PlaylistGenerator {
    public struct Result: Sendable {
        public var trackIds: [Int64]
        /// 0...1, how well the playlist satisfies the constraints.
        public var quality: Double
    }

    public let root: GeneratorConstraint
    public let universe: TrackUniverse

    public init(root: GeneratorConstraint, universe: TrackUniverse) {
        self.root = root
        self.universe = universe
    }

    /// Satisfaction of `constraint` for `playlist` (0...1).
    func score(_ constraint: GeneratorConstraint, _ playlist: [TrackFacts]) -> Double {
        func soften(_ s: Double, _ strength: Double) -> Double { 1 - max(0, min(1, strength)) * (1 - s) }
        func compare(_ value: Double, _ target: Double, _ comparison: GeneratorConstraint.Comparison, tolerance: Double) -> Double {
            let scale = max(tolerance, 1e-6)
            switch comparison {
            case .about: return exp(-abs(value - target) / scale)
            case .atLeast: return value >= target ? 1 : exp(-(target - value) / scale)
            case .atMost: return value <= target ? 1 : exp(-(value - target) / scale)
            }
        }
        switch constraint {
        case .group(let all, let children):
            guard !children.isEmpty else { return 1 }
            let scores = children.map { score($0, playlist) }
            return all ? scores.reduce(1, *) : (scores.max() ?? 1)
        case .matchTags(let q, let invert, let strength):
            guard !playlist.isEmpty else { return soften(0, strength) }
            let set = universe.searches[q] ?? []
            let matching = playlist.filter { set.contains($0.id) != invert }.count
            return soften(Double(matching) / Double(playlist.count), strength)
        case .duration(let seconds, let comparison, let strength):
            let total = Double(playlist.reduce(0) { $0 + $1.durationMs }) / 1000
            return soften(compare(total, Double(seconds), comparison, tolerance: max(60, Double(seconds) * 0.05)), strength)
        case .trackCount(let n, let comparison, let strength):
            return soften(compare(Double(playlist.count), Double(n), comparison, tolerance: max(1, Double(n) * 0.1)), strength)
        case .totalSize(let mb, let comparison, let strength):
            let total = Double(playlist.reduce(0) { $0 + $1.fileSize }) / 1_048_576
            return soften(compare(total, Double(mb), comparison, tolerance: max(5, Double(mb) * 0.05)), strength)
        case .preventDuplicates(let field):
            guard !playlist.isEmpty else { return 1 }
            let keys = playlist.map { t -> String in
                switch field {
                case .track: String(t.id)
                case .artist: TextFolding.fold(t.artist)
                case .album: t.albumKey
                }
            }
            return Double(Set(keys).count) / Double(keys.count)
        case .spreadArtists(let strength):
            guard playlist.count > 1 else { return 1 }
            let artists = playlist.map { TextFolding.fold($0.artist) }
            var collisions = 0
            for i in artists.indices {
                for j in (i + 1)..<min(artists.count, i + 3) where artists[i] == artists[j] && !artists[i].isEmpty { collisions += 1 }
            }
            return soften(1 - Double(collisions) / Double(playlist.count), strength)
        case .checkpoint(let q, let at, let strength):
            let set = universe.searches[q] ?? []
            var start = 0.0
            var best = Double.infinity
            for t in playlist {
                if set.contains(t.id) { best = min(best, abs(start - Double(at))) }
                start += Double(t.durationMs) / 1000
            }
            return soften(best.isFinite ? exp(-best / 120) : 0, strength)
        }
    }

    /// Tracks the playlist may draw from: hard (strength 1) tag filters at the top level narrow it.
    func domain() -> [TrackFacts] {
        var tracks = universe.tracks
        if case .group(true, let children) = root {
            for case .matchTags(let q, let invert, let strength) in children where strength >= 1 {
                let set = universe.searches[q] ?? []
                tracks = tracks.filter { set.contains($0.id) != invert }
            }
        }
        return tracks
    }

    func initialLength(_ domain: [TrackFacts]) -> Int {
        let average = domain.isEmpty ? 240 : Double(domain.reduce(0) { $0 + $1.durationMs }) / Double(domain.count) / 1000
        func find(_ c: GeneratorConstraint) -> Int? {
            switch c {
            case .group(_, let children): return children.lazy.compactMap(find).first
            case .trackCount(let n, _, _): return n
            case .duration(let s, _, _): return max(1, Int((Double(s) / max(1, average)).rounded()))
            default: return nil
            }
        }
        return min(domain.count, find(root) ?? 20)
    }

    public func run(iterations: Int = 4000, rng: inout some RandomNumberGenerator) -> Result {
        let domain = domain()
        guard !domain.isEmpty else { return Result(trackIds: [], quality: 0) }
        var current = (0..<initialLength(domain)).map { _ in domain.randomElement(using: &rng)! }
        var currentScore = score(root, current)
        var best = current
        var bestScore = currentScore
        for step in 0..<iterations {
            let temperature = max(0.0005, 0.25 * (1 - Double(step) / Double(iterations)))
            var candidate = current
            switch Int.random(in: 0..<4, using: &rng) {
            case 0:
                candidate.insert(domain.randomElement(using: &rng)!, at: Int.random(in: 0...candidate.count, using: &rng))
            case 1 where candidate.count > 1:
                candidate.remove(at: Int.random(in: 0..<candidate.count, using: &rng))
            case 2 where candidate.count > 1:
                candidate.swapAt(Int.random(in: 0..<candidate.count, using: &rng), Int.random(in: 0..<candidate.count, using: &rng))
            default:
                if candidate.isEmpty {
                    candidate.append(domain.randomElement(using: &rng)!)
                } else {
                    candidate[Int.random(in: 0..<candidate.count, using: &rng)] = domain.randomElement(using: &rng)!
                }
            }
            let candidateScore = score(root, candidate)
            if candidateScore >= currentScore || Double.random(in: 0..<1, using: &rng) < exp((candidateScore - currentScore) / temperature) {
                current = candidate
                currentScore = candidateScore
                if currentScore > bestScore {
                    best = current
                    bestScore = currentScore
                    if bestScore >= 0.999 { break }
                }
            }
        }
        return Result(trackIds: best.map(\.id), quality: bestScore)
    }
}
