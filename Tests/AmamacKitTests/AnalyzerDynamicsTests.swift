import Testing
@testable import AmamacPlayback

/// The analyzer's bar physics and frame history, independent of drawing.
struct AnalyzerDynamicsTests {
    @Test func barsRiseAtOnceAndStartOverWhenTheBandCountChanges() {
        var bars = SpectrumDynamics()
        bars.advance(to: [0, 0], elapsed: 0, fallSpeed: 3)
        bars.advance(to: [0.8, 0.3], elapsed: 1 / 30, fallSpeed: 3)
        #expect(bars.levels == [0.8, 0.3])
        bars.advance(to: [0.5, 0.5, 0.5], elapsed: 1 / 30, fallSpeed: 3)
        #expect(bars.levels == [0.5, 0.5, 0.5])
        #expect(bars.peaks == [0.5, 0.5, 0.5])
    }

    @Test func fallingDoesNotDependOnTheFrameRate() {
        func level(afterOneSecondAt fps: Int) -> Float {
            var bars = SpectrumDynamics()
            bars.advance(to: [1], elapsed: 0, fallSpeed: 2)
            for _ in 0..<fps { bars.advance(to: [0], elapsed: 1 / Double(fps), fallSpeed: 2) }
            return bars.levels[0]
        }
        let expected = 1 - SpectrumDynamics.fallPerSecond(2)
        #expect(abs(level(afterOneSecondAt: 20) - expected) < 0.001)
        #expect(abs(level(afterOneSecondAt: 120) - expected) < 0.001)
    }

    @Test func peaksHoldThenFallSlowerThanTheBars() {
        var bars = SpectrumDynamics()
        bars.advance(to: [1], elapsed: 0, fallSpeed: 3)
        for _ in 0..<9 { bars.advance(to: [0], elapsed: 0.04, fallSpeed: 3) }
        // 0.36 s: still inside the hold.
        #expect(bars.peaks[0] == 1)
        #expect(bars.levels[0] < 1)
        for _ in 0..<10 { bars.advance(to: [0], elapsed: 0.04, fallSpeed: 3) }
        #expect(bars.peaks[0] < 1)
        #expect(bars.peaks[0] > bars.levels[0])
    }

    @Test func historyKeepsTheNewestFramesInOrder() {
        var history = SpectrumHistory(capacity: 3)
        #expect(history.frame(age: 0) == nil)
        for value in 1...5 { history.append([Float(value)]) }
        #expect(history.count == 3)
        #expect(history.frames == [[3], [4], [5]])
        #expect(history.frame(age: 0) == [5])
        #expect(history.frame(age: 2) == [3])
        #expect(history.frame(age: 3) == nil)
        history.removeAll()
        #expect(history.count == 0)
        history.append([9])
        #expect(history.frames == [[9]])
    }
}
