import AppKit
import AmamacCore
import GRDB

/// Owns playback: picks the engine, follows the navigator, records statistics and keeps the
/// engine's gapless "upcoming" track in sync with every playlist change.
@MainActor
@Observable
final class PlayerController {
    enum State: Equatable { case stopped, playing, paused, buffering }
    enum Backend { case none, local, stream }

    private(set) var state: State = .stopped
    /// The item being played (may have been removed from the playlist).
    private(set) var currentItem: PlaylistItem?
    private(set) var volume: Int
    private(set) var isMuted = false
    /// Incremented when statistics of the current track change (rating, play count).
    private(set) var statisticsRevision = 0

    @ObservationIgnored let model: PlaylistModel
    @ObservationIgnored let proxy: PlaylistProxy
    @ObservationIgnored let navigator: PlaylistNavigator
    @ObservationIgnored let database: LibraryDatabase
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let local = LocalAudioEngine()
    @ObservationIgnored let stream = StreamEngine()
    @ObservationIgnored private(set) var backend: Backend = .none
    @ObservationIgnored private var expectingStart: PlaylistItemID?
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var lastPosition: TimeInterval = 0
    @ObservationIgnored private var positionTimer: Timer?
    @ObservationIgnored private var consecutiveErrors = 0
    @ObservationIgnored private var listeners: [UUID: (PlayerEvent) -> Void] = [:]

    enum PlayerEvent {
        case trackChanged
        case stateChanged
        case seeked
        case volumeChanged
        case streamTitleChanged
    }

    init(model: PlaylistModel, proxy: PlaylistProxy, navigator: PlaylistNavigator, database: LibraryDatabase,
         settings: AppSettings) {
        self.model = model
        self.proxy = proxy
        self.navigator = navigator
        self.database = database
        self.settings = settings
        volume = settings.volume
        isMuted = settings.bool(AppSettings.Key.muted)
        applyVolume()
        Task { [weak self] in
            guard let events = self?.local.events else { return }
            for await event in events { self?.handle(event, from: .local) }
        }
        Task { [weak self] in
            guard let events = self?.stream.events else { return }
            for await event in events { self?.handle(event, from: .stream) }
        }
        model.observe { [weak self] change in
            switch change {
            case .queueChanged, .stopAfterChanged: self?.updateUpcoming()
            default: break
            }
        }
        proxy.onChange { [weak self] in self?.updateUpcoming() }
    }

    @discardableResult
    func addListener(_ handler: @escaping (PlayerEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    private func emit(_ event: PlayerEvent) { for l in listeners.values { l(event) } }

    // MARK: Time

    var currentTime: TimeInterval {
        switch backend {
        case .local: local.currentTime ?? 0
        case .stream: stream.currentTime ?? 0
        case .none: 0
        }
    }

    var duration: TimeInterval {
        switch backend {
        case .local: local.totalTime ?? currentItem?.duration ?? 0
        case .stream: stream.duration ?? currentItem?.duration ?? 0
        case .none: currentItem?.duration ?? 0
        }
    }

    var canSeek: Bool {
        switch backend {
        case .local: local.supportsSeeking
        case .stream: stream.supportsSeeking
        case .none: false
        }
    }

    var isActive: Bool { state != .stopped }

    // MARK: Transport

    /// Plays a specific playlist item (double-click, Return).
    func play(_ id: PlaylistItemID, startAt position: TimeInterval = 0) {
        guard let item = model.item(id) else { return }
        finishSession(reachedEnd: false)
        navigator.commitAdvance(to: id)
        start(item, at: position)
    }

    /// Play / Pause toggle; starts the active (or first) item when stopped.
    func playPause() {
        switch state {
        case .playing, .buffering: pause()
        case .paused: resume()
        case .stopped: playFromStop()
        }
    }

    func playFromStop() {
        if let active = model.activeID, model.contains(active) {
            play(active)
        } else if let next = navigator.nextIgnoringStopAfter() {
            play(next)
        }
    }

    func pause() {
        guard state == .playing || state == .buffering else { return }
        let fade = settings.bool(AppSettings.Key.fadeOutOnPause) && backend == .local
        if fade {
            local.fadeOut(duration: Double(settings.int(AppSettings.Key.fadeOutDuration)) / 1000) { [weak self] in
                Task { @MainActor in self?.local.pause() }
            }
        } else {
            backend == .local ? local.pause() : stream.pause()
        }
        setState(.paused)
    }

    func resume() {
        guard state == .paused else { return }
        backend == .local ? local.resume() : stream.resume()
        setState(.playing)
    }

    func stop() {
        guard state != .stopped else { return }
        finishSession(reachedEnd: false)
        if settings.bool(AppSettings.Key.fadeOutOnStop) && backend == .local && state == .playing {
            local.fadeOut(duration: Double(settings.int(AppSettings.Key.fadeOutDuration)) / 1000) { [weak self] in
                Task { @MainActor in self?.completeStop() }
            }
        } else {
            completeStop()
        }
    }

    private func completeStop() {
        local.stop()
        stream.stop()
        local.restoreMixerVolume()
        backend = .none
        setState(.stopped)
        emit(.trackChanged)
    }

    func next() {
        guard let id = navigator.nextIgnoringStopAfter() else {
            if state != .stopped { stop() }
            return
        }
        if state == .stopped || state == .paused {
            // Like Amarok: moving while stopped just changes the active track.
            if state == .stopped {
                navigator.commitAdvance(to: id)
                emit(.trackChanged)
                return
            }
        }
        play(id)
    }

    func previous() {
        // Restart the current track when more than a few seconds in.
        if state != .stopped && currentTime > 5 {
            seek(to: 0)
            return
        }
        guard let id = navigator.peekPrevious() else {
            seek(to: 0)
            return
        }
        if state == .stopped {
            navigator.commitAdvance(to: id, backward: true)
            emit(.trackChanged)
            return
        }
        finishSession(reachedEnd: false)
        navigator.commitAdvance(to: id, backward: true)
        if let item = model.item(id) { start(item, at: 0) }
    }

    func seek(to time: TimeInterval) {
        guard canSeek else { return }
        let t = max(0, min(time, max(0, duration - 0.5)))
        switch backend {
        case .local: local.seek(to: t)
        case .stream: stream.seek(to: t)
        case .none: return
        }
        lastPosition = t
        emit(.seeked)
    }

    func seek(by delta: TimeInterval) { seek(to: currentTime + delta) }

    func setVolume(_ value: Int) {
        volume = max(0, min(100, value))
        settings.volume = volume
        if isMuted && volume > 0 { isMuted = false; settings.set(false, AppSettings.Key.muted) }
        applyVolume()
        emit(.volumeChanged)
    }

    func toggleMute() {
        isMuted.toggle()
        settings.set(isMuted, AppSettings.Key.muted)
        applyVolume()
        emit(.volumeChanged)
    }

    private func applyVolume() {
        // Perceptual curve: squared slider value.
        let linear = isMuted ? 0 : Float(volume) / 100
        let v = linear * linear
        local.setVolume(v)
        stream.setVolume(v)
    }

    /// "Stop after current track" toggle.
    func toggleStopAfterCurrent() {
        guard let id = currentItem?.id ?? model.activeID else { return }
        model.setStopAfter(model.stopAfterID == id ? nil : id)
    }

    // MARK: Engine plumbing

    private func start(_ item: PlaylistItem, at position: TimeInterval) {
        consecutiveErrors = item.id == currentItem?.id ? consecutiveErrors : 0
        currentItem = item
        lastPosition = position
        sessionStart = Date()
        if item.url.isFileURL && !item.isStream {
            if backend == .stream { stream.stop() }
            backend = .local
            expectingStart = item.id
            do {
                try local.play(url: item.url, itemID: item.id, gainDB: gain(for: item))
                if position > 0 {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        self.local.seek(to: position)
                    }
                }
                setState(.playing)
            } catch {
                expectingStart = nil
                handlePlaybackError(error.localizedDescription, item: item.id)
                return
            }
        } else {
            if backend == .local { local.stop() }
            backend = .stream
            expectingStart = item.id
            stream.play(url: item.url, itemID: item.id)
            setState(.buffering)
        }
        startPositionTimer()
        updateUpcoming()
        emit(.trackChanged)
    }

    private func handle(_ event: EngineEvent, from source: Backend) {
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
            finishSession(reachedEnd: true)
            if let stopAfter = model.stopAfterID, stopAfter == currentItem?.id {
                model.setStopAfter(nil)
                halt(moveTo: navigator.nextIgnoringStopAfter())
            } else if let next = navigator.peekNext(), let item = model.item(next) {
                // The bridge could not pre-enqueue (format change, stream, very short track).
                navigator.commitAdvance(to: next)
                start(item, at: 0)
            } else {
                halt(moveTo: nil)
            }
        case .error(let message, let id):
            handlePlaybackError(message, item: id ?? currentItem?.id)
        case .streamTitle(let title, let id):
            model.updateItem(id) { $0.streamTitle = title }
            if currentItem?.id == id { currentItem?.streamTitle = title }
            emit(.streamTitleChanged)
        }
    }

    private func halt(moveTo next: PlaylistItemID?) {
        local.stop()
        stream.stop()
        backend = .none
        if let next { navigator.commitAdvance(to: next) }
        setState(.stopped)
        emit(.trackChanged)
    }

    private func handlePlaybackError(_ message: String, item: PlaylistItemID?) {
        let name = item.flatMap { model.item($0)?.track.displayTitle } ?? "track"
        AppEnvironment.shared?.status.showMessage("Could not play “\(name)”: \(message)")
        consecutiveErrors += 1
        guard consecutiveErrors < 5, let next = navigator.peekNext(), next != item, let nextItem = model.item(next) else {
            halt(moveTo: nil)
            return
        }
        navigator.commitAdvance(to: next)
        start(nextItem, at: 0)
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        if new == .stopped { positionTimer?.invalidate(); positionTimer = nil }
        updateUpcoming()
        emit(.stateChanged)
    }

    private func startPositionTimer() {
        guard positionTimer == nil else { return }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .playing else { return }
                self.lastPosition = self.currentTime
            }
        }
    }

    /// Recomputes the track the engine should enqueue next.
    func updateUpcoming() {
        guard backend == .local, state != .stopped, let current = currentItem?.id,
              let nextID = navigator.peekNext(), let next = model.item(nextID),
              next.url.isFileURL, !next.isStream else {
            local.setUpcoming(nil)
            return
        }
        local.setUpcoming(UpcomingTrack(itemID: nextID, url: next.url, gainDB: gain(for: next), after: current))
    }

    func gain(for item: PlaylistItem) -> Float {
        ReplayGain.gain(for: item.track, mode: settings.replayGainMode, preamp: settings.double(AppSettings.Key.replayGainPreamp))
    }

    // MARK: Statistics

    private func finishSession(reachedEnd: Bool) {
        guard let item = currentItem, sessionStart != nil else { return }
        sessionStart = nil
        guard let trackId = item.track.id, item.source == .collection else { return }
        let duration = item.duration > 0 ? item.duration : self.duration
        let played = reachedEnd ? duration : lastPosition
        let db = database
        Task {
            let stats = try? await db.writer.write { db -> TrackStatistics in
                var stats = try TrackStatistics.fetchOne(db, key: trackId) ?? TrackStatistics(trackId: trackId)
                PlayStatistics.apply(to: &stats, playedSeconds: played, duration: duration, reachedEnd: reachedEnd)
                try stats.save(db)
                return stats
            }
            if let stats { self.statisticsUpdated(trackId: trackId, stats) }
        }
    }

    func statisticsUpdated(trackId: Int64, _ stats: TrackStatistics) {
        model.updateTrack(id: trackId) { $0.statistics = stats }
        if currentItem?.track.id == trackId { currentItem?.statistics = stats }
        statisticsRevision += 1
    }

    /// Sets the rating (0...10) of a track and updates every copy of it.
    func setRating(_ rating: Int, trackId: Int64) {
        let db = database
        Task {
            let stats = try? await db.writer.write { db -> TrackStatistics in
                var stats = try TrackStatistics.fetchOne(db, key: trackId) ?? TrackStatistics(trackId: trackId)
                stats.rating = max(0, min(10, rating))
                try stats.save(db)
                return stats
            }
            if let stats {
                self.statisticsUpdated(trackId: trackId, stats)
                NotificationCenter.default.post(name: AppEnvironment.collectionChanged, object: nil)
            }
        }
    }

    // MARK: Remote commands

    func handle(_ command: RemoteCommand) {
        switch command {
        case .play: state == .paused ? resume() : (state == .stopped ? playFromStop() : ())
        case .pause: pause()
        case .togglePlayPause: playPause()
        case .stop: stop()
        case .next: next()
        case .previous: previous()
        case .seek(let t): seek(to: t)
        case .skipForward(let d): seek(by: d)
        case .skipBackward(let d): seek(by: -d)
        }
    }
}
