import AmamacModels
import Foundation

/// Edit Track Details for one or many tracks: what each track had, what it has now, which
/// values differ between tracks, and the changes to write. With several tracks, edits apply to
/// all of them unless `perTrack` is on.
public struct TagEditSession: Sendable {
    public internal(set) var tracks: [Track]
    public internal(set) var original: [Values]
    public internal(set) var current: [Values]
    /// With several tracks: edit only the track at `index`.
    public var perTrack: Bool
    /// The track shown when one track is edited at a time.
    public var index: Int {
        didSet { index = min(max(0, index), max(0, tracks.count - 1)) }
    }
    var originalLabels: [Set<String>]
    var labels: [Set<String>]
    var originalPlayCounts: [Int]
    var playCounts: [Int]
    var covers: [CoverEdit?]

    /// `playCounts` and `labels` are per track (missing entries count as 0 and none).
    public init(tracks: [Track], playCounts: [Int] = [], labels: [[String]] = []) {
        self.tracks = tracks
        let values = tracks.map { Values(track: $0) }
        original = values
        current = values
        perTrack = tracks.count == 1
        index = 0
        let counts = tracks.indices.map { $0 < playCounts.count ? playCounts[$0] : 0 }
        originalPlayCounts = counts
        self.playCounts = counts
        let sets = tracks.indices.map { $0 < labels.count ? Set(labels[$0]) : [] }
        originalLabels = sets
        self.labels = sets
        covers = Array(repeating: nil, count: tracks.count)
    }

    public var count: Int { tracks.count }
    public var isMultiple: Bool { tracks.count > 1 }
    public var showsOneTrack: Bool { perTrack || !isMultiple }
    /// The tracks an edit applies to.
    public var targets: [Int] { showsOneTrack ? (tracks.isEmpty ? [] : [index]) : Array(tracks.indices) }

    /// Takes the values read from the files (the collection may be older than a file, and only
    /// files know sort names). Fields already edited keep the edit.
    public mutating func adoptFileValues(_ values: [Values?]) {
        for i in tracks.indices where i < values.count {
            guard let file = values[i] else { continue }
            for field in Field.allCases {
                if current[i][field] == original[i][field] { current[i][field] = file[field] }
                original[i][field] = file[field]
            }
            if current[i].compilation == original[i].compilation { current[i].compilation = file.compilation }
            original[i].compilation = file.compilation
        }
    }

    // MARK: Fields

    /// The shown value: the current track's, or the value all tracks share ("" when they differ).
    public func value(_ field: Field) -> String {
        if showsOneTrack { return tracks.isEmpty ? "" : current[index][field] }
        return common(field) ?? ""
    }

    /// Whether the tracks have different values (only when editing all of them).
    public func isMixed(_ field: Field) -> Bool { !showsOneTrack && common(field) == nil }

    private func common(_ field: Field) -> String? {
        guard let first = current.first?[field] else { return "" }
        return current.allSatisfy { $0[field] == first } ? first : nil
    }

    public mutating func set(_ field: Field, _ value: String) {
        for i in targets { current[i][field] = value }
    }

    /// Whether the shown value can be saved: every changed track's value is acceptable.
    public func isValid(_ field: Field) -> Bool {
        tracks.indices.allSatisfy { i in
            current[i][field] == original[i][field] || field.accepts(current[i][field])
        }
    }

    public var invalidFields: [Field] { Field.allCases.filter { !isValid($0) } }

    public var compilation: TriState {
        let values = Set(targets.map { current[$0].compilation })
        return values.count > 1 ? .mixed : values.first == true ? .on : .off
    }

    public mutating func setCompilation(_ on: Bool) {
        for i in targets { current[i].compilation = on }
    }

    // MARK: Cover

    /// The pending cover change shared by the shown tracks (nil when none, or when they differ).
    public var coverEdit: CoverEdit? {
        let edits = targets.map { covers[$0] }
        guard let first = edits.first, edits.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// `nil` drops a pending change.
    public mutating func setCover(_ edit: CoverEdit?) {
        for i in targets { covers[i] = edit }
    }

    // MARK: Library-only values

    public func playCount(at i: Int) -> Int { playCounts.indices.contains(i) ? playCounts[i] : 0 }

    /// Changes the library's play count; it is never written to the file.
    public mutating func setPlayCount(_ count: Int, at i: Int) {
        guard playCounts.indices.contains(i) else { return }
        playCounts[i] = max(0, count)
    }

    /// Labels of the shown track, or of any selected track.
    public var shownLabels: [String] {
        Set(targets.flatMap { labels[$0] }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Takes the collection's labels once loaded; labels already edited keep the edit.
    public mutating func adoptLabels(_ loaded: [[String]]) {
        for i in tracks.indices where i < loaded.count {
            let names = Set(loaded[i])
            if labels[i] == originalLabels[i] { labels[i] = names }
            originalLabels[i] = names
        }
    }

    public mutating func addLabel(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        for i in targets { labels[i].insert(name) }
    }

    public mutating func removeLabel(_ name: String) {
        for i in targets { labels[i].remove(name) }
    }
}
