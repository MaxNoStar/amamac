import Foundation

/// The most recent spectrum frames, for analyzers that draw echoes or a scrolling history. Holds at
/// most `capacity` frames; appending beyond that drops the oldest.
public struct SpectrumHistory: Sendable {
    public let capacity: Int
    private var storage: [[Float]] = []
    /// Index of the oldest frame once `storage` is full.
    private var start = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { storage.count }

    public mutating func append(_ frame: [Float]) {
        if storage.count < capacity {
            storage.append(frame)
        } else {
            storage[start] = frame
            start = (start + 1) % capacity
        }
    }

    /// The frame `age` steps back (0 is the newest), or nil when the history is shorter.
    public func frame(age: Int) -> [Float]? {
        guard age >= 0, age < storage.count else { return nil }
        return storage[(start + storage.count - 1 - age) % storage.count]
    }

    /// All frames, oldest first.
    public var frames: [[Float]] {
        Array(storage[start...] + storage[..<start])
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        start = 0
    }
}
