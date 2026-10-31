import AmamacBase
import Foundation

/// Picks the next tracks for dynamic mode.
public struct DynamicGenerator {
    public let bias: Bias
    public let universe: TrackUniverse

    public init(bias: Bias, universe: TrackUniverse) {
        self.bias = bias
        self.universe = universe
    }

    /// Candidate ids for `bias` given the previous track; nil means "any track".
    func candidates(_ bias: Bias, previous: TrackFacts?, rng: inout some RandomNumberGenerator) -> Set<Int64>? {
        switch bias {
        case .random:
            return nil
        case .search(let q):
            return universe.searches[q] ?? []
        case .and(let children):
            var result: Set<Int64>?
            for child in children {
                guard let set = candidates(child, previous: previous, rng: &rng) else { continue }
                result = result.map { $0.intersection(set) } ?? set
            }
            return result
        case .or(let children):
            var result = Set<Int64>()
            for child in children {
                guard let set = candidates(child, previous: previous, rng: &rng) else { return nil }
                result.formUnion(set)
            }
            return result
        case .not(let child):
            guard let set = candidates(child, previous: previous, rng: &rng) else { return [] }
            return Set(universe.tracks.map(\.id)).subtracting(set)
        case .partition(let parts):
            let total = parts.reduce(0) { $0 + max(0, $1.weight) }
            guard total > 0 else { return nil }
            var pick = Double.random(in: 0..<total, using: &rng)
            for part in parts {
                pick -= max(0, part.weight)
                if pick < 0 { return candidates(part.bias, previous: previous, rng: &rng) }
            }
            return candidates(parts[parts.count - 1].bias, previous: previous, rng: &rng)
        case .ifElse(let children):
            for child in children {
                let set = candidates(child, previous: previous, rng: &rng)
                if set == nil || !(set!.isEmpty) { return set }
            }
            return []
        case .albumPlay(let mode):
            guard let previous, !previous.album.isEmpty else {
                // Start albums at their first track.
                let firsts = Dictionary(grouping: universe.tracks.filter { !$0.album.isEmpty }, by: \.albumKey)
                    .compactMap { $0.value.min { $0.albumOrder < $1.albumOrder }?.id }
                return Set(firsts)
            }
            let album = universe.tracks.filter { $0.albumKey == previous.albumKey && $0.id != previous.id }
            switch mode {
            case .sameAlbum:
                return Set(album.map(\.id))
            case .follows:
                return Set(album.filter { $0.albumOrder > previous.albumOrder }.map(\.id))
            case .directlyFollows:
                let next = album.filter { $0.albumOrder > previous.albumOrder }.min { $0.albumOrder < $1.albumOrder }
                return next.map { [$0.id] } ?? []
            }
        case .quizPlay(let field):
            guard let previous else { return nil }
            func value(_ t: TrackFacts) -> String {
                TextFolding.fold(field == .title ? t.title : (field == .artist ? t.artist : t.album)).filter(\.isLetter)
            }
            guard let last = value(previous).last else { return nil }
            return Set(universe.tracks.filter { $0.id != previous.id && value($0).first == last }.map(\.id))
        }
    }

    /// The next track after `history` (most recent last). Tracks in `exclude` are skipped; when
    /// nothing satisfies the bias, any track is used (as Amarok does).
    public func next(after history: [Int64], exclude: Set<Int64>, rng: inout some RandomNumberGenerator) -> Int64? {
        let previous = history.last.flatMap { universe.byId[$0] }
        let allowed = candidates(bias, previous: previous, rng: &rng)
        if let allowed {
            let pool = allowed.subtracting(exclude)
            if !pool.isEmpty { return pool.randomElement(using: &rng) }
        }
        let fallback = universe.tracks.lazy.map(\.id).filter { !exclude.contains($0) }
        let array = Array(fallback)
        return array.randomElement(using: &rng)
    }

    /// `count` tracks following `history`. Without `allowDuplicates`, tracks already in
    /// `history` or `existing` are not chosen again (unless the collection runs out).
    public func generate(count: Int, history: [Int64], existing: Set<Int64>, allowDuplicates: Bool,
                         rng: inout some RandomNumberGenerator) -> [Int64] {
        var result: [Int64] = []
        var context = history
        var used = allowDuplicates ? Set<Int64>() : existing.union(history)
        for _ in 0..<count {
            var pick = next(after: context, exclude: used, rng: &rng)
            if pick == nil && !used.isEmpty { pick = next(after: context, exclude: [], rng: &rng) }
            guard let id = pick else { break }
            result.append(id)
            context.append(id)
            if !allowDuplicates { used.insert(id) }
        }
        return result
    }
}
