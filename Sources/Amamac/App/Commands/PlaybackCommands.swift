import AmamacPlayback
import AppKit

/// Playback menu: transport, seeking, volume, Replay Gain and Play Media.
@MainActor
final class PlaybackCommands: NSObject, NSMenuItemValidation {
    private unowned let env: AppEnvironment

    init(env: AppEnvironment) { self.env = env }

    @objc func playPause(_ sender: Any?) { env.player.playPause() }
    @objc func stopPlayback(_ sender: Any?) { env.player.stop() }
    @objc func nextTrack(_ sender: Any?) { env.player.next() }
    @objc func previousTrack(_ sender: Any?) { env.player.previous() }
    @objc func toggleStopAfterCurrent(_ sender: Any?) { env.player.toggleStopAfterCurrent() }
    @objc func volumeUp(_ sender: Any?) { env.player.setVolume(env.player.volume + 5) }
    @objc func volumeDown(_ sender: Any?) { env.player.setVolume(env.player.volume - 5) }
    @objc func toggleMute(_ sender: Any?) { env.player.toggleMute() }

    @objc func seekForward(_ sender: NSMenuItem) { env.player.seek(by: Double(env.settings.int(seekKey(sender.tag)))) }
    @objc func seekBackward(_ sender: NSMenuItem) { env.player.seek(by: -Double(env.settings.int(seekKey(sender.tag)))) }

    private func seekKey(_ tag: Int) -> String {
        switch tag {
        case 0: AppSettings.Key.seekShort
        case 2: AppSettings.Key.seekLong
        default: AppSettings.Key.seekMedium
        }
    }

    @objc func setReplayGainMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ReplayGainMode(rawValue: raw) else { return }
        env.settings.replayGainMode = mode
    }

    @objc func playMedia(_ sender: Any?) {
        guard let urls = MediaOpenPanel.run(prompt: "Play") else { return }
        env.actions.addURLs(urls, mode: .appendAndPlay)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let player = env.player
        let responder = NSApp.keyWindow?.firstResponder
        let editingText = responder is NSText || responder is NSTextView
        switch menuItem.action {
        case #selector(playPause(_:)):
            let playing = player.state == .playing || player.state == .buffering
            menuItem.title = playing ? "Pause" : "Play"
            // Bare Space must reach text fields.
            return !(menuItem.keyEquivalent == " " && editingText)
        case #selector(seekForward(_:)), #selector(seekBackward(_:)):
            let bare = menuItem.keyEquivalentModifierMask.isEmpty
            if bare && (editingText || responder is NSOutlineView || responder is NSTableView) { return false }
            return player.canSeek
        case #selector(stopPlayback(_:)): return player.isActive
        case #selector(toggleStopAfterCurrent(_:)):
            let id = player.currentItem?.id ?? env.playlist.activeID
            menuItem.state = id != nil && env.playlist.stopAfterID == id ? .on : .off
            return id != nil
        case #selector(toggleMute(_:)):
            menuItem.state = player.isMuted ? .on : .off
            return true
        case #selector(setReplayGainMode(_:)):
            menuItem.state = (menuItem.representedObject as? String) == env.settings.replayGainMode.rawValue ? .on : .off
            return true
        default:
            return true
        }
    }
}
