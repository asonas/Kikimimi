import Foundation
import Testing
@testable import RecorderAudio

struct SamplePeakWindowTests {
    @Test func calibratedSineSilenceAndNonfiniteSamples() {
        var meter = SamplePeakWindow(sampleRate: 16000)
        let amplitude = pow(10.0, -18 / 20.0)
        let sine = (0..<800).map { Float(amplitude * sin(2 * .pi * 200 * Double($0) / 16000)) }
        var peaks: [Float] = []
        meter.ingest(sine) { peaks.append($0) }
        #expect(peaks.count == 1)
        #expect(abs(peaks[0] + 18) < 0.001)
        meter.ingest([Float](repeating: 0, count: 800)) { peaks.append($0) }
        #expect(peaks.last == -120)
        meter.ingest([.nan, .infinity, 0] + [Float](repeating: 0, count: 797)) { peaks.append($0) }
        #expect(peaks.last == -120)
    }
    @Test(arguments: [16000.0, 44100, 48000]) func windowsCrossChunkBoundaries(_ rate: Double) {
        var meter = SamplePeakWindow(sampleRate: rate)
        let samples = [Float](repeating: 0.25, count: Int(rate))
        var peaks: [Float] = []
        meter.ingest(Array(samples.prefix(13))) { peaks.append($0) }
        #expect(peaks.isEmpty)
        meter.ingest(Array(samples.dropFirst(13))) { peaks.append($0) }
        #expect(peaks.count == 20)
        #expect(peaks.allSatisfy { abs($0 + 12.0412) < 0.001 })
    }
}
