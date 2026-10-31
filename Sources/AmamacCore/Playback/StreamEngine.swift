@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Plays network streams (internet radio, podcasts that aren't downloaded) with AVPlayer and
/// reports ICY stream titles.
public final class StreamEngine: NSObject, AVPlayerItemMetadataOutputPushDelegate, @unchecked Sendable {
    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let player = AVPlayer()
    private let state = Mutex<(item: PlaylistItemID?, observers: [NSKeyValueObservation], token: (any NSObjectProtocol)?)>((nil, [], nil))
    private let metadataQueue = DispatchQueue(label: "amamac.stream.metadata")

    public override init() {
        var c: AsyncStream<EngineEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        let timeObserver = player.observe(\.timeControlStatus, options: [.new]) { [continuation] player, _ in
            switch player.timeControlStatus {
            case .playing:
                continuation.yield(.buffering(false))
                continuation.yield(.stateChanged(.playing))
            case .paused:
                continuation.yield(.buffering(false))
            case .waitingToPlayAtSpecifiedRate:
                continuation.yield(.buffering(true))
            @unknown default:
                break
            }
        }
        state.withLock { $0.observers = [timeObserver] }
    }

    public func play(url: URL, itemID: PlaylistItemID) {
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: metadataQueue)
        item.add(output)
        let statusObserver = item.observe(\.status, options: [.new]) { [continuation] item, _ in
            if item.status == .failed {
                continuation.yield(.error(item.error?.localizedDescription ?? "The stream could not be played.", itemID))
            }
        }
        let token = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                           queue: nil, using: Self.endHandler(continuation))
        state.withLock { s in
            if let old = s.token { NotificationCenter.default.removeObserver(old) }
            s.item = itemID
            s.observers = Array(s.observers.prefix(1)) + [statusObserver]
            s.token = token
        }
        player.replaceCurrentItem(with: item)
        player.play()
        continuation.yield(.nowPlayingChanged(itemID))
    }

    static func endHandler(_ continuation: AsyncStream<EngineEvent>.Continuation) -> @Sendable (Notification) -> Void {
        { _ in continuation.yield(.endOfAudio) }
    }

    public func pause() {
        player.pause()
        continuation.yield(.stateChanged(.paused))
    }

    public func resume() {
        player.play()
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        state.withLock { s in
            if let old = s.token { NotificationCenter.default.removeObserver(old) }
            s.token = nil
            s.item = nil
            s.observers = Array(s.observers.prefix(1))
        }
        continuation.yield(.stateChanged(.stopped))
    }

    public var isActive: Bool { state.withLock { $0.item != nil } }
    public var isPlaying: Bool { player.timeControlStatus != .paused }

    public var currentTime: TimeInterval? {
        let t = player.currentTime().seconds
        return t.isFinite ? t : nil
    }

    public var duration: TimeInterval? {
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return nil }
        return d
    }

    public var supportsSeeking: Bool { duration != nil }

    public func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }

    public func setVolume(_ volume: Float) { player.volume = max(0, min(1, volume)) }

    // MARK: Metadata

    public func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                               from track: AVPlayerItemTrack?) {
        guard let itemID = state.withLock({ $0.item }) else { return }
        for group in groups {
            for item in group.items {
                let isTitle = item.identifier == .icyMetadataStreamTitle || item.commonKey == .commonKeyTitle
                guard isTitle else { continue }
                Task {
                    if let title = try? await item.load(.stringValue), !title.isEmpty {
                        self.continuation.yield(.streamTitle(title, itemID))
                    }
                }
            }
        }
    }
}
