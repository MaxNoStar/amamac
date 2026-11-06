@preconcurrency import AVFoundation
import AmamacModels
import Foundation
import Synchronization

/// Plays local files on two decks (see `Deck`): one plays, the other stands by for crossfades.
/// Tracks chain gaplessly on the playing deck; `Crossfader` hands over to the other deck when
/// the next track should fade in. Fades and the analyzer tap follow whichever deck is playing.
public final class LocalAudioEngine: @unchecked Sendable {
    /// Band centre frequencies (Hz).
    public static let equalizerFrequencies: [Float] = [29, 59, 119, 237, 474, 947, 1_900, 3_800, 7_500, 15_000]

    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    /// What happened in playback lately, for Help › Diagnostics.
    public let eventLog = PlaybackEventLog()
    let decks: [Deck]
    let crossfader = Crossfader()
    /// The track to play after the current one, with its decoder once it has been opened ahead of
    /// time; taken by the gapless path or the crossfader.
    private let upcoming = Mutex<Queued?>(nil)
    /// The sample rate every track is converted to (see `PlaybackDecoder`), chosen at each `play`.
    private let sampleRate = Mutex<Double>(44_100)
    private let prepareQueue = DispatchQueue(label: "amamac.engine.prepare", qos: .userInitiated)
    private let routing = Mutex(Routing())
    /// Bumped by every fade and cancellation; a fade step only acts while its generation is current.
    private let fadeGeneration = Mutex(0)

    struct Routing {
        var active = 0
        var tap: SpectrumTap?
    }

    struct Queued {
        var track: UpcomingTrack
        var prepared: PlaybackDecoder?
    }

    public init() {
        var continuation: AsyncStream<EngineEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        decks = [Deck(index: 0, continuation: continuation), Deck(index: 1, continuation: continuation)]
        for deck in decks { deck.bridge.engine = self }
        crossfader.engine = self
    }

    // MARK: Decks

    var activeDeck: Deck { decks[routing.withLock { $0.active }] }

    func isActive(_ deck: Deck) -> Bool { routing.withLock { $0.active == deck.index } }

    func deck(otherThan deck: Deck) -> Deck { decks[1 - deck.index] }

    /// Makes `deck` the one whose events, position and analyzer tap count.
    func makeActive(_ deck: Deck) {
        routing.withLock { r in
            guard r.active != deck.index else { return }
            if let tap = r.tap {
                decks[r.active].removeTap()
                deck.installTap(tap)
            }
            r.active = deck.index
        }
    }

    public var isCrossfading: Bool { crossfader.isCrossfading }

    // MARK: Upcoming

    /// Sets (or clears) the track to play when the current one ends, and opens its file in the
    /// background so nothing has to be read at the join (opening an MP3 reads the whole file).
    public func setUpcoming(_ upcoming: UpcomingTrack?) {
        let changed = self.upcoming.withLock { q -> Bool in
            guard q?.track != upcoming else { return false }
            q = upcoming.map { Queued(track: $0) }
            return true
        }
        guard changed, let upcoming else { return }
        let rate = playbackSampleRate
        prepareQueue.async { [weak self] in
            // A file that can't be opened is reported when it is due, through the usual paths.
            guard let decoder = try? PlaybackDecoder(url: upcoming.url, sampleRate: rate, gainDB: upcoming.gainDB),
                  (try? decoder.open()) != nil else { return }
            self?.upcoming.withLock { q in
                if q?.track == upcoming, q?.prepared == nil { q?.prepared = decoder }
            }
        }
    }

    func peekUpcoming() -> UpcomingTrack? { upcoming.withLock { $0?.track } }

    /// Takes the upcoming track if it follows `item`; with `crossfadeOnly`, only one meant to crossfade.
    /// The decoder is the one opened ahead of time, or nil if it wasn't ready (see `makeDecoder`).
    func takeUpcoming(after item: PlaylistItemID?, crossfadeOnly: Bool) -> (track: UpcomingTrack, decoder: PlaybackDecoder?)? {
        let rate = playbackSampleRate
        return upcoming.withLock { q in
            guard let next = q, next.track.after == item else { return nil }
            if crossfadeOnly, case .gapless = next.track.transition { return nil }
            q = nil
            return (next.track, next.prepared?.sampleRate == rate ? next.prepared : nil)
        }
    }

    /// A decoder for `track` in the current playback format, opened here, so a file that can't be read fails where the next track is started (and is
    /// reported as `upcomingFailed`) instead of later on the player's decoding thread, where the
    /// error would look like the current track's.
    func makeDecoder(for track: UpcomingTrack) throws -> PlaybackDecoder {
        let decoder = try PlaybackDecoder(url: track.url, sampleRate: playbackSampleRate, gainDB: track.gainDB)
        try decoder.open()
        return decoder
    }

    var playbackSampleRate: Double { sampleRate.withLock { $0 } }

    /// Sends an event that doesn't come from a deck's player (the crossfader's).
    func emit(_ event: EngineEvent) { continuation.yield(event) }

    /// The output device's own rate, so the mixer has nothing left to convert, but never below
    /// 44.1 kHz: a headset in call mode reports 16 or 24 kHz.
    static func playbackSampleRate(device: AudioObjectID) -> Double {
        let rate = AudioDevices.nominalSampleRate(device) ?? 44_100
        return rate >= 44_100 ? rate : 44_100
    }

    // MARK: Transport

    /// Starts playing `url` immediately, replacing anything queued and ending any crossfade.
    public func play(url: URL, itemID: PlaylistItemID, gainDB: Float = 0) throws {
        crossfader.finishNow()
        cancelFade()
        let deck = activeDeck
        let rate = Self.playbackSampleRate(device: deck.player.outputDeviceID)
        sampleRate.withLock { $0 = rate }
        eventLog.add("Play \(url.lastPathComponent) at \(Int(rate)) Hz")
        try deck.play(PlaybackDecoder(url: url, sampleRate: rate, gainDB: gainDB), itemID: itemID)
        crossfader.watch(true)
    }

    public func pause() {
        for deck in decks where deck.isPlaying { _ = deck.player.pause() }
        crossfader.watch(false)
    }

    public func resume() {
        cancelFade()
        for deck in decks where deck.isPaused { _ = deck.player.resume() }
        crossfader.watch(true)
    }

    public func stop() {
        crossfader.finishNow()
        for deck in decks { deck.player.stop() }
        upcoming.withLock { $0 = nil }
        crossfader.watch(false)
    }

    public var isPlaying: Bool { activeDeck.isPlaying }
    public var isPaused: Bool { activeDeck.isPaused }
    public var currentTime: TimeInterval? { activeDeck.currentTime }
    public var totalTime: TimeInterval? { activeDeck.totalTime }
    public var supportsSeeking: Bool { activeDeck.player.supportsSeeking }

    /// Seeks the playing track; a running crossfade finishes first.
    @discardableResult
    public func seek(to time: TimeInterval) -> Bool {
        crossfader.finishNow()
        return activeDeck.player.seek(time: max(0, time))
    }

    /// Device volume, 0...1.
    public func setVolume(_ volume: Float) {
        for deck in decks { try? deck.player.setVolume(max(0, min(1, volume))) }
    }

    /// Fades both decks to silence over `duration`, then runs `completion` on the main queue.
    /// `play`, `resume` and `cancelFade` abandon the fade; its completion then never runs.
    public func fadeOut(duration: TimeInterval, completion: @escaping @Sendable () -> Void) {
        let generation = fadeGeneration.withLock { g -> Int in
            g += 1
            return g
        }
        guard duration > 0 else { completion(); return }
        let decks = self.decks
        let steps = max(1, Int(duration / 0.02))
        let start = activeDeck.fadeGain
        let queue = DispatchQueue(label: "amamac.fade")
        for i in 1...steps {
            queue.asyncAfter(deadline: .now() + Double(i) * duration / Double(steps)) { [weak self] in
                guard let self, self.fadeGeneration.withLock({ $0 }) == generation else { return }
                for deck in decks { deck.setFadeGain(start * Float(steps - i) / Float(steps)) }
                if i == steps {
                    DispatchQueue.main.async {
                        if self.fadeGeneration.withLock({ $0 }) == generation { completion() }
                    }
                }
            }
        }
    }

    /// Stops a running fade and restores full volume.
    public func cancelFade() {
        fadeGeneration.withLock { $0 += 1 }
        for deck in decks { deck.setFadeGain(1) }
    }

    public var isFading: Bool { activeDeck.fadeGain < 1 }

    public func restoreMixerVolume() { cancelFade() }

    public var outputDeviceID: AudioObjectID { activeDeck.player.outputDeviceID }

    public func setOutputDevice(_ id: AudioObjectID) throws {
        for deck in decks { try deck.player.setOutputDeviceID(id) }
    }

    // MARK: Equalizer / gain

    public func setEqualizer(enabled: Bool, preamp: Float, bands: [Float]) {
        for deck in decks { deck.setEqualizer(enabled: enabled, preamp: preamp, bands: bands) }
    }

    /// ReplayGain for the current track (dB), for the audio decoded from now on.
    public func setTrackGain(_ gain: Float) {
        (activeDeck.player.nowPlaying as? PlaybackDecoder)?.setGain(gain)
    }

    // MARK: Analyzer

    /// Starts copying output samples into `tap` (installed only while an analyzer is visible).
    public func setSpectrumTap(_ tap: SpectrumTap?) {
        routing.withLock { r in
            if r.tap != nil { decks[r.active].removeTap() }
            r.tap = tap
            if let tap { decks[r.active].installTap(tap) }
        }
    }
}
