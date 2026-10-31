import AmamacBase
import AmamacModels
import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac from idling to sleep while music plays, and pauses before the Mac sleeps.
@MainActor
final class SleepInhibitor {
    private unowned let env: AppEnvironment
    private var assertion: IOPMAssertionID = 0

    init(env: AppEnvironment) {
        self.env = env
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
    }

    func update() {
        let playing = env.player.state == .playing || env.player.state == .buffering
        let want = playing && env.settings.bool(AppSettings.Key.inhibitSleep)
        if want, assertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Amamac is playing music" as CFString, &id) == kIOReturnSuccess {
                assertion = id
            }
        } else if !want, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    private func willSleep() {
        if env.settings.bool(AppSettings.Key.pauseOnSleep), env.player.state == .playing { env.player.pause() }
    }
}
