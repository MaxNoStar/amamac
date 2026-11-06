import Foundation
import Testing
@testable import AmamacPlayback

struct PlaybackWatchdogTests {
    let start = Date(timeIntervalSinceReferenceDate: 0)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func movingPlaybackIsLeftAlone() {
        var dog = PlaybackWatchdog()
        for tick in 0..<40 {
            let t = Double(tick) * 0.25
            #expect(dog.check(enginePlaying: true, position: t, duration: 200, at: at(t)) == .none)
        }
    }

    @Test func aStalledPositionRestartsTheTrackWhereItStood() {
        var dog = PlaybackWatchdog()
        #expect(dog.check(enginePlaying: true, position: 40, duration: 200, at: at(0)) == .none)
        #expect(dog.check(enginePlaying: true, position: 40, duration: 200, at: at(2.9)) == .none)
        #expect(dog.check(enginePlaying: true, position: 40, duration: 200, at: at(3)) == .restart(at: 40))
        // After acting it starts over rather than firing on every tick.
        #expect(dog.check(enginePlaying: true, position: 40, duration: 200, at: at(3.25)) == .none)
    }

    @Test func aStallNearTheEndMovesOn() {
        var dog = PlaybackWatchdog()
        #expect(dog.check(enginePlaying: true, position: 198.5, duration: 200, at: at(0)) == .none)
        #expect(dog.check(enginePlaying: true, position: 198.5, duration: 200, at: at(3)) == .advance)
    }

    @Test func anEngineThatStoppedIsCaughtSooner() {
        var dog = PlaybackWatchdog()
        #expect(dog.check(enginePlaying: true, position: 10, duration: 200, at: at(0)) == .none)
        #expect(dog.check(enginePlaying: false, position: nil, duration: nil, at: at(0.5)) == .none)
        #expect(dog.check(enginePlaying: false, position: nil, duration: nil, at: at(1)) == .restart(at: 10))
        #expect(dog.check(enginePlaying: true, position: 199, duration: 200, at: at(2)) == .none)
        #expect(dog.check(enginePlaying: false, position: 199, duration: 200, at: at(3)) == .advance)
    }

    @Test func resetForgetsTheStall() {
        var dog = PlaybackWatchdog()
        #expect(dog.check(enginePlaying: true, position: 40, duration: 200, at: at(0)) == .none)
        dog.reset()
        #expect(dog.check(enginePlaying: true, position: 40, duration: 200, at: at(2.5)) == .none)
        #expect(dog.check(enginePlaying: true, position: 40, duration: 200, at: at(5)) == .none)
        #expect(dog.check(enginePlaying: true, position: 40, duration: 200, at: at(5.5)) == .restart(at: 40))
    }

    @Test func eventLogKeepsTheLatestHundredInOrder() {
        let log = PlaybackEventLog()
        for i in 0..<130 { log.add("event \(i)", at: at(Double(i))) }
        let all = log.all
        #expect(all.count == PlaybackEventLog.capacity)
        #expect(all.first?.message == "event 30" && all.last?.message == "event 129")
        let lines = log.report().split(separator: "\n")
        #expect(lines.count == 100)
        #expect(lines.last?.hasSuffix(" event 129") == true)
        #expect(lines.last?.split(separator: " ").first?.count == 12, "HH:mm:ss.SSS")
    }
}
