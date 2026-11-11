import Foundation

/// Display-only sample peaks. No padding, overlap removal, or mutation of the source PCM.
struct SamplePeakWindow {
    private let windowFrames: Int
    private var frames = 0
    private var peak: Float = 0
    init(sampleRate: Double) { windowFrames = max(1, Int((sampleRate * 0.05).rounded())) }

    mutating func ingest(_ samples: [Float], emit: (Float) -> Void) {
        for sample in samples {
            if sample.isFinite { peak = max(peak, abs(sample)) }
            frames += 1
            if frames == windowFrames {
                emit(peak > 0 ? max(-120, 20 * log10(peak)) : -120)
                frames = 0; peak = 0
            }
        }
    }
}
