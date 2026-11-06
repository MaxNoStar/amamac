import Testing
@testable import AmamacPlayback

struct CallPausePolicyTests {
    @Test func pausesForACallAndResumesAfterIt() {
        var policy = CallPausePolicy()
        #expect(policy.microphoneChanged(inUse: true, playing: true) == .pause)
        #expect(policy.pausedForCall)
        // Core Audio repeats itself; nothing new happened.
        #expect(policy.microphoneChanged(inUse: true, playing: false) == .none)
        #expect(policy.microphoneChanged(inUse: false, playing: false) == .resume)
        #expect(!policy.pausedForCall)
        #expect(policy.microphoneChanged(inUse: false, playing: true) == .none)
    }

    @Test func nothingPlayingMeansNothingToResume() {
        var policy = CallPausePolicy()
        #expect(policy.microphoneChanged(inUse: true, playing: false) == .none)
        #expect(policy.microphoneChanged(inUse: false, playing: false) == .none)
    }

    @Test func whatTheUserDoesDuringTheCallStands() {
        var policy = CallPausePolicy()
        #expect(policy.microphoneChanged(inUse: true, playing: true) == .pause)
        policy.userChangedPlayback()
        #expect(policy.microphoneChanged(inUse: false, playing: true) == .none)
    }

    @Test func offMeansHandsOff() {
        var policy = CallPausePolicy(isEnabled: false)
        #expect(policy.microphoneChanged(inUse: true, playing: true) == .none)
        #expect(policy.microphoneChanged(inUse: false, playing: true) == .none)
        policy.setEnabled(true)
        #expect(policy.microphoneChanged(inUse: true, playing: true) == .pause)
        policy.setEnabled(false)
        #expect(policy.microphoneChanged(inUse: false, playing: false) == .none, "turned off mid-call: no resume")
    }

    @Test func aCallAlreadyRunningAtLaunchDoesntPauseLaterPlayback() {
        var policy = CallPausePolicy()
        #expect(policy.microphoneChanged(inUse: true, playing: false) == .none)
        // Pressing Play during the call is the user's choice.
        #expect(policy.microphoneChanged(inUse: true, playing: true) == .none)
    }
}
