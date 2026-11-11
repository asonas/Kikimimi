import Testing
@testable import RecorderCore

struct LevelMeterScaleTests {
    @Test(arguments: [(-60 as Float, 0), (-24, 18), (-22, 19), (-18, 21), (-10, 25), (0, 30), (5, 30), (-90, 0)])
    func segmentMapping(_ row: (Float, Int)) {
        #expect(LevelMeterScale.litSegments(dbFS: row.0) == row.1)
    }
    @Test func thresholdsAndInvalidInput() {
        #expect(LevelMeterScale.band(segment: 22) == .green) // upper edge -14
        #expect(LevelMeterScale.band(segment: 23) == .amber) // upper edge -12
        #expect(LevelMeterScale.band(segment: 27) == .amber) // upper edge -4
        #expect(LevelMeterScale.band(segment: 28) == .red) // upper edge -2 crosses -3
        #expect(LevelMeterScale.band(segment: 29) == .red)
        #expect(LevelMeterScale.litSegments(dbFS: nil) == 0)
        #expect(LevelMeterScale.litSegments(dbFS: .nan) == 0)
        #expect(LevelMeterScale.litSegments(dbFS: -.infinity) == 0)
        #expect(LevelMeterScale.position(dbFS: -60) == 0)
        #expect(LevelMeterScale.position(dbFS: 0) == 1)
        #expect(LevelMeterScale.position(dbFS: -30) == 0.5)
        #expect(LevelMeterScale.valueText(dbFS: nil) == "−∞ dBFS")
        #expect(LevelMeterScale.valueText(dbFS: -120) == "−∞ dBFS")
        #expect(LevelMeterScale.valueText(dbFS: -18) == "−18 dBFS")
        #expect(LevelMeterScale.valueText(dbFS: 0) == "0 dBFS")
    }
}
