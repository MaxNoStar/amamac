import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import AmamacPlayback

struct AudioRouteMonitorTests {
    final class Fake: Sendable {
        let route = Mutex(AudioRoute())
        let delivered = Mutex<[AudioRoute]>([])
    }

    static func monitor(_ fake: Fake) -> AudioRouteMonitor {
        AudioRouteMonitor(debounce: 0.1, read: { _ in fake.route.withLock { $0 } }, listens: false,
                          deliveryQueue: DispatchQueue(label: "test.route")) { route in
            fake.delivered.withLock { $0.append(route) }
        }
    }

    @Test func aBurstOfChangesArrivesAsOneRoute() async throws {
        let fake = Fake()
        let monitor = Self.monitor(fake)
        fake.route.withLock {
            $0.outputRate = 16_000
            $0.recordingApps = ["com.example.call"]
        }
        for _ in 0..<5 {
            monitor.noteChange()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(400))
        let delivered = fake.delivered.withLock { $0 }
        #expect(delivered.count == 1)
        #expect(delivered.first?.microphoneInUse == true && delivered.first?.outputRate == 16_000)
        #expect(monitor.current == delivered.first)
    }

    @Test func nothingIsDeliveredWhenNothingChanged() async throws {
        let fake = Fake()
        let monitor = Self.monitor(fake)
        monitor.noteChange()
        monitor.watchOutput(42)
        try await Task.sleep(for: .milliseconds(400))
        #expect(fake.delivered.withLock { $0 }.isEmpty)
    }

    @Test func theRealRouteIsReadable() {
        let route = AudioRoute.read(output: nil)
        if route.defaultOutput != nil {
            #expect((route.outputRate ?? 0) > 0)
            #expect((route.outputChannels ?? 0) >= 1)
            #expect(route.outputAlive)
        }
        #expect(!route.recordingApps.contains("local.amamac.tests"), "this process never counts")
        #expect(route.summary.contains("microphone"))
    }
}
