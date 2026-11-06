import AmamacModels
import AmamacPlayback
import Foundation

/// What the engines report: tracks joining, ending, failing, stream titles.
extension PlayerController {
    func handle(_ event: EngineEvent, from source: Backend) {
        guard source == backend else { return }
        switch event {
        case .nowPlayingChanged(let id):
            guard let id else { return }
            if id == expectingStart {
                expectingStart = nil
                return
            }
            // Gapless transition to a pre-enqueued track (or a repeat of the same one).
            finishSession(reachedEnd: true)
            navigator.commitAdvance(to: id)
            if let item = model.item(id) { currentItem = item }
            sessionStart = Date()
            lastPosition = 0
            startPosition = 0
            watchdog.reset()
            consecutiveErrors = 0
            updateUpcoming()
            emit(.trackChanged)
        case .stateChanged(let s):
            switch s {
            case .playing: if state != .playing { setState(.playing) }
            case .paused: if state == .playing { setState(.paused) }
            case .stopped: break
            }
        case .buffering(let b):
            if b && state == .playing { setState(.buffering) } else if !b && state == .buffering { setState(.playing) }
        case .endOfAudio:
            advanceAfterEnd()
        case .endedEarly(let id, let message):
            guard id == nil || id == currentItem?.id else { return }
            let name = currentItem?.track.displayTitle ?? "track"
            status.showMessage("“\(name)” stopped early: \(message)")
            finishSession(reachedEnd: false)
            advanceAfterEnd()
        case .upcomingFailed(let id, let message):
            failedItems.insert(id)
            let name = model.item(id)?.track.displayTitle ?? "track"
            status.showMessage("Could not play “\(name)”: \(message)")
            updateUpcoming()
        case .error(let message, let id?) where id != currentItem?.id:
            // The next track, failing while the current one still plays out.
            handle(.upcomingFailed(id, message), from: source)
        case .error(let message, let id):
            handlePlaybackError(message, item: id ?? currentItem?.id)
        case .outputFailed(let message):
            recoverOutput(message)
        case .streamTitle(let title, let id):
            model.updateItem(id) { $0.streamTitle = title }
            if currentItem?.id == id { currentItem?.streamTitle = title }
            emit(.streamTitleChanged)
        }
    }

    /// The current track ended on its own: honour "stop after", then start whatever comes next,
    /// passing over items that already failed to open (at most 5 in a row).
    func advanceAfterEnd() {
        finishSession(reachedEnd: true)
        if let stopAfter = model.stopAfterID, stopAfter == currentItem?.id {
            model.setStopAfter(nil)
            halt(moveTo: navigator.nextIgnoringStopAfter())
            return
        }
        var skipped = 0
        while let next = navigator.peekNext(), let item = model.item(next) {
            navigator.commitAdvance(to: next)
            if failedItems.contains(next) && skipped < 5 {
                skipped += 1
                continue
            }
            // Started explicitly: the engine had nothing queued (a stream, a skipped item).
            start(item, at: 0)
            return
        }
        halt(moveTo: nil)
    }

    func halt(moveTo next: PlaylistItemID?) {
        local.stop()
        stream.stop()
        backend = .none
        if let next { navigator.commitAdvance(to: next) }
        setState(.stopped)
        emit(.trackChanged)
    }

    func handlePlaybackError(_ message: String, item: PlaylistItemID?) {
        let name = item.flatMap { model.item($0)?.track.displayTitle } ?? "track"
        status.showMessage("Could not play “\(name)”: \(message)")
        consecutiveErrors += 1
        guard consecutiveErrors < 5, let next = navigator.peekNext(), next != item, let nextItem = model.item(next) else {
            halt(moveTo: nil)
            return
        }
        navigator.commitAdvance(to: next)
        start(nextItem, at: 0)
    }
}
