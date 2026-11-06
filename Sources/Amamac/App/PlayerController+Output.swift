import AmamacModels
import AmamacPlayback
import Foundation

/// How and where the sound goes: audio settings, the output device, following route changes,
/// pausing for calls, and getting going again when the output (not the track) fails or playback
/// silently stalls.
extension PlayerController {
    var gainSettings: [String] {
        [settings.replayGainMode.rawValue, String(settings.double(AppSettings.Key.replayGainPreamp)),
         String(settings.double(AppSettings.Key.replayGainFallback))]
    }

    /// Re-applies ReplayGain, crossfading and the output device when their settings change (any writer).
    func audioSettingsChanged() {
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
        let pauseDuringCalls = settings.bool(AppSettings.Key.pauseDuringCalls)
        if pauseDuringCalls != callPolicy.isEnabled {
            callPolicy.setEnabled(pauseDuringCalls)
            if !pauseDuringCalls { cancelCallResume() }
        }
    }

    func startFollowingRoute() {
        callPolicy.setEnabled(settings.bool(AppSettings.Key.pauseDuringCalls))
        let monitor = AudioRouteMonitor { [weak self] route in
            Task { @MainActor in self?.routeChanged(route) }
        }
        routeMonitor = monitor
        route = monitor.current
        // A call that is already running at launch isn't one starting.
        _ = callPolicy.microphoneChanged(inUse: route.microphoneInUse, playing: false)
        applyOutputDevice()
    }

    /// Routes both engines to the chosen device, or to the system default when it is unset or gone.
    func applyOutputDevice() {
        let uid = settings.string(AppSettings.Key.outputDevice) ?? ""
        appliedOutputUID = uid
        let chosen = uid.isEmpty ? nil : AudioDevices.device(uid: uid)
        if let target = chosen ?? AudioDevices.defaultOutputDevice(), local.outputDeviceIDs.contains(where: { $0 != target }) {
            do {
                try local.setOutputDevice(target)
            } catch {
                status.showMessage("Could not switch the output device: \(error.localizedDescription)")
            }
        }
        routeMonitor?.watchOutput(local.outputDeviceID)
        stream.setOutputDevice(uid: chosen != nil ? uid : nil)
    }

    /// One settled route change (the monitor collapses bursts).
    func routeChanged(_ new: AudioRoute) {
        let old = route
        route = new
        local.eventLog.add("Route: \(new.summary)")
        if new.devices != old.devices || new.defaultOutput != old.defaultOutput || new.outputAlive != old.outputAlive {
            applyOutputDevice()
        }
        if new.outputRate != old.outputRate || new.outputChannels != old.outputChannels {
            local.revalidateOutput()
        }
        if callResume != nil { scheduleCallResume() }
        switch callPolicy.microphoneChanged(inUse: new.microphoneInUse, playing: state == .playing || state == .buffering) {
        case .none:
            break
        case .pause:
            local.eventLog.add("Paused for a call")
            status.showMessage("Paused while another app uses the microphone")
            pausePlayback()
        case .resume:
            scheduleCallResume()
        }
    }

    /// Resumes after a call once the route has been quiet for 1.5 s: a headset needs a moment to
    /// leave call mode, and audio started before that sounds like a phone line. Every route change
    /// in between starts the wait again.
    func scheduleCallResume() {
        callResume?.cancel()
        callResume = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.callResume = nil
            self.local.eventLog.add("Resuming after the call")
            self.local.revalidateOutput()
            self.resumePlayback()
        }
    }

    func cancelCallResume() {
        callResume?.cancel()
        callResume = nil
    }

    /// Play, Pause, Stop or another track by hand: whatever the user chose stands after a call.
    func userChangedPlayback() {
        callPolicy.userChangedPlayback()
        cancelCallResume()
    }

    /// The engine couldn't keep its output running (or playback stalled): start the same track
    /// again where it was, after 0.5, 1.5 and 3 s, without counting it against the track. A fourth
    /// failure before playback runs well again stops.
    func recoverOutput(_ message: String, at position: TimeInterval? = nil) {
        guard backend == .local, let item = currentItem, state == .playing else { return }
        outputRecovery?.cancel()
        let delays: [TimeInterval] = [0.5, 1.5, 3]
        guard outputRetries < delays.count else {
            local.eventLog.add("Output failed again (\(message)); stopped")
            status.showMessage("Playback stopped: the audio output keeps failing (\(message))")
            halt(moveTo: nil)
            return
        }
        let delay = delays[outputRetries]
        outputRetries += 1
        let resumeAt = position ?? lastPosition
        local.eventLog.add("Output failed (\(message)); restarting “\(item.track.displayTitle)” at \(Int(resumeAt)) s")
        outputRecovery = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.outputRecovery = nil
            guard self.currentItem?.id == item.id, self.state == .playing else { return }
            self.applyOutputDevice()
            self.start(item, at: resumeAt)
        }
    }

    /// Seeks a just-started track once its decoder is ready (opening can take a moment).
    func seekWhenReady(_ id: PlaylistItemID, to position: TimeInterval) {
        Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.currentItem?.id == id, self.backend == .local else { return }
                if self.local.totalTime != nil, self.local.seek(to: position) {
                    self.lastPosition = position
                    self.watchdog.reset()
                    return
                }
            }
        }
    }

    /// From the position timer while playing: notes when the track plays well (which clears the
    /// error counters) and lets the watchdog catch playback that stopped without telling anyone.
    func checkPlayback() {
        guard backend == .local, !local.isCrossfading, outputRecovery == nil else {
            watchdog.reset()
            return
        }
        let position = local.currentTime
        if let position, position - startPosition >= 3 {
            consecutiveErrors = 0
            outputRetries = 0
        }
        let length = duration
        switch watchdog.check(enginePlaying: local.isPlaying, position: position, duration: length > 0 ? length : nil, at: Date()) {
        case .none:
            break
        case .advance:
            local.eventLog.add("Watchdog: “\(currentItem?.track.displayTitle ?? "track")” stopped at its end; moving on")
            advanceAfterEnd()
        case .restart(let at):
            recoverOutput("playback stalled", at: at)
        }
    }
}
