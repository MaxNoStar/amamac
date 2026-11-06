import Foundation
import Synchronization
@testable import AmamacPlayback

/// Reads one engine's events from a single task for the whole test. Waiting with a timeout then
/// leaves the stream intact: cancelling the task that iterates an AsyncStream finishes the stream,
/// so every later wait would see nothing.
final class EngineEventRecorder: Sendable {
    private struct State {
        var events: [EngineEvent] = []
        /// Events already handed out by `collect`.
        var consumed = 0
    }

    private let state = Mutex(State())

    init(_ engine: LocalAudioEngine) {
        let stream = engine.events
        Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.state.withLock { $0.events.append(event) }
            }
        }
    }

    /// The events after the last `collect`, up to the first one for which `stop` holds. Throws
    /// `EngineTests.Timeout` after `seconds`.
    func collect(seconds: Double, until stop: ([EngineEvent]) -> Bool) async throws -> [EngineEvent] {
        let deadline = Date().addingTimeInterval(seconds)
        var checked = 0
        while true {
            let (start, pending) = state.withLock { ($0.consumed, Array($0.events[$0.consumed...])) }
            while checked < pending.count {
                checked += 1
                let prefix = Array(pending.prefix(checked))
                if stop(prefix) {
                    state.withLock { $0.consumed = start + checked }
                    return prefix
                }
            }
            if Date() >= deadline {
                state.withLock { $0.consumed = start + pending.count }
                throw EngineTests.Timeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Everything recorded so far, without consuming it.
    var all: [EngineEvent] { state.withLock { $0.events } }
}
