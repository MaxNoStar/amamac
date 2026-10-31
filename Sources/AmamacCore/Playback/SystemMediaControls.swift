import AppKit
@preconcurrency import MediaPlayer

/// Commands from media keys, Control Center, headphones and the Touch Bar.
public enum RemoteCommand: Sendable, Equatable {
    case play, pause, togglePlayPause, stop, next, previous
    case seek(TimeInterval)
    case skipForward(TimeInterval), skipBackward(TimeInterval)
}

/// Thin wrappers around MPNowPlayingInfoCenter / MPRemoteCommandCenter. Handlers are created here
/// (nonisolated) because the system invokes them off the main thread.
public enum SystemMediaControls {
    public static func registerRemoteCommands(_ handler: @escaping @Sendable (RemoteCommand) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ make: @escaping @Sendable (MPRemoteCommandEvent) -> RemoteCommand?) {
            command.isEnabled = true
            command.addTarget { event in
                guard let cmd = make(event) else { return .commandFailed }
                handler(cmd)
                return .success
            }
        }
        add(center.playCommand) { _ in .play }
        add(center.pauseCommand) { _ in .pause }
        add(center.togglePlayPauseCommand) { _ in .togglePlayPause }
        add(center.stopCommand) { _ in .stop }
        add(center.nextTrackCommand) { _ in .next }
        add(center.previousTrackCommand) { _ in .previous }
        add(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) }
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { event in .skipForward((event as? MPSkipIntervalCommandEvent)?.interval ?? 10) }
        add(center.skipBackwardCommand) { event in .skipBackward((event as? MPSkipIntervalCommandEvent)?.interval ?? 10) }
    }

    public struct Info: Sendable {
        public var title: String
        public var artist: String
        public var album: String
        public var duration: TimeInterval?
        public var elapsed: TimeInterval
        public var playing: Bool
        public var isLiveStream: Bool

        public init(title: String, artist: String, album: String, duration: TimeInterval?, elapsed: TimeInterval,
                    playing: Bool, isLiveStream: Bool = false) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.elapsed = elapsed
            self.playing = playing
            self.isLiveStream = isLiveStream
        }
    }

    public static func update(_ info: Info?, artwork: NSImage?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyAlbumTitle: info.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: info.isLiveStream,
        ]
        if let d = info.duration { dict[MPMediaItemPropertyPlaybackDuration] = d }
        if let artwork { dict[MPMediaItemPropertyArtwork] = makeArtwork(artwork) }
        center.nowPlayingInfo = dict
        center.playbackState = info.playing ? .playing : .paused
    }

    static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
