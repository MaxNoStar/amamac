import AmamacDatabase
import AmamacLibrary
import AmamacModels
import AmamacPlayback
import AmamacPlaylist
import AppKit

/// Owns playback: picks the engine, follows the navigator, records statistics and keeps the
/// engine's gapless "upcoming" track in sync with every playlist change.
@MainActor
@Observable
final class PlayerController {
    enum State: Equatable { case stopped, playing, paused, buffering }
    enum Backend { case none, local, stream }

    private(set) var state: State = .stopped
    /// The item being played (may have been removed from the playlist).
    var currentItem: PlaylistItem?
    private(set) var volume: Int
    private(set) var isMuted = false
    /// Incremented when statistics of the current track change (rating, play count).
    var statisticsRevision = 0

    @ObservationIgnored let model: PlaylistModel
    @ObservationIgnored let proxy: PlaylistProxy
    @ObservationIgnored let navigator: PlaylistNavigator
    @ObservationIgnored let database: LibraryDatabase
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let status: StatusCenter
    /// Called before statistics are written into a file, so the folder watcher ignores the change.
    @ObservationIgnored var willWriteFile: ((String) -> Void)?
    @ObservationIgnored let local = LocalAudioEngine()
    @ObservationIgnored let stream = StreamEngine()
    @ObservationIgnored var backend: Backend = .none
    @ObservationIgnored var expectingStart: PlaylistItemID?
    @ObservationIgnored var sessionStart: Date?
    @ObservationIgnored var lastPosition: TimeInterval = 0
    @ObservationIgnored private var positionTimer: Timer?
    @ObservationIgnored var consecutiveErrors = 0
    /// Items that failed to open as the next track this session; moving on skips them until they
    /// are played on purpose.
    @ObservationIgnored var failedItems: Set<PlaylistItemID> = []
    @ObservationIgnored private var listeners: [UUID: (PlayerEvent) -> Void] = [:]
    @ObservationIgnored private var appliedGainSettings: [String] = []
    @ObservationIgnored private var appliedCrossfade = CrossfadePolicy()
    @ObservationIgnored private var appliedOutputUID: String?
    @ObservationIgnored private var deviceObservation: AudioDeviceObservation?

    enum PlayerEvent {
        case trackChanged
        case stateChanged
        case seeked
        case volumeChanged
        case streamTitleChanged
    }

    init(model: PlaylistModel, proxy: PlaylistProxy, navigator: PlaylistNavigator, database: LibraryDatabase,
         settings: AppSettings, status: StatusCenter) {
        self.model = model
        self.proxy = proxy
        self.navigator = navigator
        self.database = database
        self.settings = settings
        self.status = status
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
        appliedGainSettings = gainSettings
        appliedCrossfade = settings.crossfadePolicy
        applyOutputDevice()
        deviceObservation = AudioDevices.observeChanges { [weak self] in
            Task { @MainActor in self?.applyOutputDevice() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: settings.defaults,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioSettingsChanged() }
        }
    }

    // MARK: Audio settings

    private var gainSettings: [String] {
        [settings.replayGainMode.rawValue, String(settings.double(AppSettings.Key.replayGainPreamp)),
         String(settings.double(AppSettings.Key.replayGainFallback))]
    }

    /// Re-applies ReplayGain, crossfading and the output device when their settings change (any writer).
    private func audioSettingsChanged() {
        if gainSettings != appliedGainSettings {
            appliedGainSettings = gainSettings
            if backend == .local, let item = currentItem { local.setTrackGain(gain(for: item)) }
            updateUpcoming()
        }
        if settings.crossfadePolicy != appliedCrossfade {
            appliedCrossfade = settings.crossfadePolicy
            updateUpcoming()
        }
        if (settings.string(AppSettings.Key.outputDevice) ?? "") != appliedOutputUID { applyOutputDevice() }
    }

    /// Routes both engines to the chosen device, or to the system default when it is unset or gone.
    func applyOutputDevice() {
        let uid = settings.string(AppSettings.Key.outputDevice) ?? ""
        appliedOutputUID = uid
        let chosen = uid.isEmpty ? nil : AudioDevices.device(uid: uid)
        if let target = chosen ?? AudioDevices.defaultOutputDevice(), target != local.outputDeviceID {
            do {
                try local.setOutputDevice(target)
            } catch {
                status.showMessage("Could not switch the output device: \(error.localizedDescription)")
            }
        }
        stream.setOutputDevice(uid: chosen != nil ? uid : nil)
    }

    @discardableResult
    func addListener(_ handler: @escaping (PlayerEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    func emit(_ event: PlayerEvent) { for l in listeners.values { l(event) } }

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
        failedItems.remove(id)
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

    func start(_ item: PlaylistItem, at position: TimeInterval) {
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

    func setState(_ new: State) {
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

    /// Recomputes the track the engine should play next, and whether it crossfades.
    func updateUpcoming() {
        guard backend == .local, state != .stopped, let current = currentItem,
              let nextID = navigator.peekNext(), !failedItems.contains(nextID), let next = model.item(nextID),
              next.url.isFileURL, !next.isStream else {
            local.setUpcoming(nil)
            return
        }
        local.setUpcoming(UpcomingTrack(itemID: nextID, url: next.url, gainDB: gain(for: next), after: current.id,
                                        transition: settings.crossfadePolicy.transition(from: current.track, to: next.track)))
    }

    func gain(for item: PlaylistItem) -> Float {
        ReplayGain.gain(for: item.track, mode: settings.replayGainMode, preamp: settings.double(AppSettings.Key.replayGainPreamp),
                        fallback: settings.double(AppSettings.Key.replayGainFallback))
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
