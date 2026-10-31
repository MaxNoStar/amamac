import AmamacBase
import AmamacModels
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let playPause = Self("playPause", initial: .init(.p, modifiers: [.control, .option]))
    static let nextTrack = Self("nextTrack", initial: .init(.rightArrow, modifiers: [.control, .option]))
    static let previousTrack = Self("previousTrack", initial: .init(.leftArrow, modifiers: [.control, .option]))
    static let stopPlayback = Self("stopPlayback")
    static let stopAfterCurrent = Self("stopAfterCurrent", initial: .init(.v, modifiers: [.control, .option, .shift]))
    static let volumeUp = Self("volumeUp", initial: .init(.equal, modifiers: [.control, .option]))
    static let volumeDown = Self("volumeDown", initial: .init(.minus, modifiers: [.control, .option]))
    static let toggleMute = Self("toggleMute", initial: .init(.m, modifiers: [.control, .option]))
    static let showOSD = Self("showOSD", initial: .init(.o, modifiers: [.control, .option]))
    static let addMedia = Self("addMedia", initial: .init(.a, modifiers: [.control, .option]))
    static let rate1 = Self("rate1", initial: .init(.one, modifiers: [.control, .option]))
    static let rate2 = Self("rate2", initial: .init(.two, modifiers: [.control, .option]))
    static let rate3 = Self("rate3", initial: .init(.three, modifiers: [.control, .option]))
    static let rate4 = Self("rate4", initial: .init(.four, modifiers: [.control, .option]))
    static let rate5 = Self("rate5", initial: .init(.five, modifiers: [.control, .option]))
}

@MainActor
enum HotKeys {
    static let all: [(KeyboardShortcuts.Name, String)] = [
        (.playPause, "Play / Pause"), (.stopPlayback, "Stop"), (.nextTrack, "Next Track"), (.previousTrack, "Previous Track"),
        (.stopAfterCurrent, "Stop After Current Track"), (.volumeUp, "Increase Volume"), (.volumeDown, "Decrease Volume"),
        (.toggleMute, "Mute"), (.showOSD, "Show On-Screen Display"), (.addMedia, "Add Media…"),
        (.rate1, "Rate ★"), (.rate2, "Rate ★★"), (.rate3, "Rate ★★★"), (.rate4, "Rate ★★★★"), (.rate5, "Rate ★★★★★"),
    ]

    static func register(env: AppEnvironment, osd: OSDController) {
        let player = env.player
        KeyboardShortcuts.onKeyUp(for: .playPause) { player.playPause() }
        KeyboardShortcuts.onKeyUp(for: .stopPlayback) { player.stop() }
        KeyboardShortcuts.onKeyUp(for: .nextTrack) { player.next() }
        KeyboardShortcuts.onKeyUp(for: .previousTrack) { player.previous() }
        KeyboardShortcuts.onKeyUp(for: .stopAfterCurrent) {
            player.toggleStopAfterCurrent()
            let on = env.playlist.stopAfterID != nil
            osd.showMessage(on ? "Stop after this track" : "Continue after this track", symbol: on ? "stop.circle" : "play.circle")
        }
        KeyboardShortcuts.onKeyUp(for: .volumeUp) { player.setVolume(player.volume + 5) }
        KeyboardShortcuts.onKeyUp(for: .volumeDown) { player.setVolume(player.volume - 5) }
        KeyboardShortcuts.onKeyUp(for: .toggleMute) { player.toggleMute() }
        KeyboardShortcuts.onKeyUp(for: .showOSD) {
            if let item = player.currentItem, player.isActive { osd.show(trackContent(item, osd: osd), force: true) } else {
                osd.show(.message("Nothing is playing", symbol: "music.note", level: nil), force: true)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .addMedia) {
            NSApp.activate()
            NSApp.sendAction(#selector(PlaylistCommands.addMedia(_:)), to: nil, from: nil)
        }
        for (stars, name) in [(1, KeyboardShortcuts.Name.rate1), (2, .rate2), (3, .rate3), (4, .rate4), (5, .rate5)] {
            KeyboardShortcuts.onKeyUp(for: name) {
                guard let id = player.currentItem?.track.id, player.currentItem?.source == .collection else { return }
                player.setRating(stars * 2, trackId: id)
                osd.showMessage("Rated " + RatingText.stars(stars * 2), symbol: "star.fill")
            }
        }
    }

    private static func trackContent(_ item: PlaylistItem, osd: OSDController) -> OSDContent {
        let track = item.track
        return .track(title: item.streamTitle ?? track.displayTitle,
                      detail: [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "),
                      rating: item.source == .collection ? item.statistics?.rating ?? 0 : nil,
                      length: item.duration > 0 ? TimeFormatting.duration(item.duration) : "",
                      albumKey: item.source == .collection && !track.album.isEmpty ? track.albumKey : nil)
    }
}
