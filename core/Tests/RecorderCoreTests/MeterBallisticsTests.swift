import Testing
@testable import RecorderCore

struct MeterBallisticsTests {
    @Test func prototypeAttackHoldReleaseStaleAndReducedMotion() {
        var meter = MeterBallistics()
        #expect(meter.frame(dbFS: -18, at: 0, reducedMotion: false, stale: false).level == -18)
        var reading = meter.frame(dbFS: -60, at: 0.016, reducedMotion: false, stale: false)
        for milliseconds in stride(from: 32, through: 784, by: 16) {
            reading = meter.frame(dbFS: -60, at: Double(milliseconds) / 1000, reducedMotion: false, stale: false)
        }
        #expect(reading.peak == -18)
        reading = meter.frame(dbFS: -60, at: 0.816, reducedMotion: false, stale: false)
        #expect((reading.peak ?? 0) < -18)
        #expect(abs(reading.level - (-37.584)) < 0.001)
        reading = meter.frame(dbFS: -30, at: 0.832, reducedMotion: false, stale: true)
        #expect(reading.level == -60)
        #expect(reading.peak == nil)
        #expect(reading.state == .inputLost)
        #expect(reading.valueText == "入力停止")
        reading = meter.frame(dbFS: -35, at: 0.850, reducedMotion: true, stale: false)
        #expect(reading.level == -35)
        #expect(reading.state == .live)
    }

    @Test func elapsedTimeIsCappedAndPeakNeverFallsBelowLevel() {
        var meter = MeterBallistics()
        _ = meter.frame(dbFS: -10, at: 0, reducedMotion: false, stale: false)
        let delayed = meter.frame(dbFS: -60, at: 100, reducedMotion: false, stale: false)
        #expect(abs(delayed.level - (-12.4)) < 0.001)
        #expect(delayed.peak! >= delayed.level)
        let backwards = meter.frame(dbFS: -60, at: 99, reducedMotion: false, stale: false)
        #expect(backwards.level == delayed.level)
    }

    @Test func silenceAndUnmeasuredDoNotInventActivity() {
        var meter = MeterBallistics()
        for value: Float? in [nil, .nan, .infinity, -.infinity] {
            let reading = meter.frame(dbFS: value, at: 0, reducedMotion: false, stale: false)
            #expect(reading.state == .unmeasured)
            #expect(reading.level == -60)
            #expect(reading.peak == nil)
            #expect(reading.valueText == "−∞ dBFS")
        }
        for time in 0..<120 {
            let reading = meter.frame(dbFS: -120, at: Double(time) / 30, reducedMotion: false, stale: false)
            #expect(reading.state == .silent)
            #expect(reading.level == -60)
            #expect(reading.peak == nil)
        }
        #expect(meter.frame(dbFS: 5, at: 5, reducedMotion: false, stale: false).level == 0)
    }
}
