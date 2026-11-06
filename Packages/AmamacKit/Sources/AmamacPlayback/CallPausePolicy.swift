import Foundation

/// Decides when playback pauses for a call and when it comes back. "A call" is another app
/// recording from a microphone (`AudioRoute.microphoneInUse`), so dictation and voice memos count
/// too. Whatever the user does in between (Play, Pause, Stop, another track) stands: the end of
/// the call then resumes nothing.
public struct CallPausePolicy: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none
        case pause
        case resume
    }

    public private(set) var isEnabled: Bool
    /// Playback is paused because of a call and resumes when it ends.
    public private(set) var pausedForCall = false
    private var microphoneInUse = false

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    public mutating func microphoneChanged(inUse: Bool, playing: Bool) -> Action {
        guard inUse != microphoneInUse else { return .none }
        microphoneInUse = inUse
        if inUse {
            guard isEnabled, playing else { return .none }
            pausedForCall = true
            return .pause
        }
        guard pausedForCall else { return .none }
        pausedForCall = false
        return .resume
    }

    /// The user changed playback by hand.
    public mutating func userChangedPlayback() {
        pausedForCall = false
    }

    /// Turning the setting off mid-call also drops the pending resume: off means hands off.
    public mutating func setEnabled(_ on: Bool) {
        isEnabled = on
        if !on { pausedForCall = false }
    }
}
