import Foundation

/// Pure. Decides where each incoming chunk lands in the track's file so that file time follows host time
/// without ever deleting speech for ordinary clock drift.
///
/// Why this exists: neither SCStream nor AVAudioEngine promises gapless delivery (SCStream may not deliver
/// during silence; devices drop buffers; device clocks drift against the host clock by tens of ppm).
/// Without this, every segment time after the first gap would be wrong, silently.
///
/// Policy is deliberately asymmetric, because losing speech is worse than a timestamp that is a few hundred ms off:
///  - drift > +tolerance  (host time ran ahead of the file: missing audio)   -> pad that much silence. Never loses speech.
///  - drift < -tolerance  (the file is ahead: a fast device clock, i.e. steady negative drift)  -> keep appending, only
///    record it in `maxAbsDriftSeconds`. A device 100 ppm fast is 0.36 s ahead after an hour; that is acceptable.
///  - a single-step *backward jump* (drift decreases by more than `backwardJump` between consecutive chunks:
///    duplicated or re-delivered audio, a timestamp reset) -> drop that much from the head of the chunk.
public struct TrackClock: Sendable, Equatable {
    public let sampleRate: Double
    public let firstHostSeconds: Double
    /// Positive drift below this is ignored. Default 100 ms > one 4096-frame buffer at 48 kHz (85 ms).
    public let tolerance: Double
    /// A step down in drift larger than this between consecutive chunks counts as duplicated audio. Default 0.5 s.
    public let backwardJump: Double

    public private(set) var framesPlaced: Int64 = 0
    public private(set) var gapFillFrames: Int64 = 0
    public private(set) var gapCount = 0
    public private(set) var overlapDroppedFrames: Int64 = 0
    public private(set) var maxAbsDriftSeconds = 0.0
    private var lastDrift = 0.0

    public init(sampleRate: Double, firstHostSeconds: Double, tolerance: Double = 0.1, backwardJump: Double = 0.5) {
        self.sampleRate = sampleRate; self.firstHostSeconds = firstHostSeconds
        self.tolerance = tolerance; self.backwardJump = backwardJump
    }

    public enum Placement: Sendable, Equatable {
        /// Write the chunk as is.
        case append
        /// Write `frames` of silence first, then the chunk.
        case padSilence(frames: Int)
        /// Skip the first `frames` of the chunk, write the rest.
        case dropLeading(frames: Int)
    }

    private func drift(chunkHostSeconds: Double) -> Double {
        chunkHostSeconds - (firstHostSeconds + Double(framesPlaced) / sampleRate)
    }

    /// Where would a chunk starting at `chunkHostSeconds` with `frameCount` frames go? Does not mutate.
    public func placement(chunkHostSeconds: Double, frameCount: Int) -> Placement {
        let d = drift(chunkHostSeconds: chunkHostSeconds)
        if d > tolerance { return .padSilence(frames: Int((d * sampleRate).rounded())) }
        let jump = d - lastDrift
        if jump < -backwardJump { return .dropLeading(frames: min(frameCount, Int((-jump * sampleRate).rounded()))) }
        return .append
    }

    public var diagnostics: ClockDiagnostics {
        ClockDiagnostics(gapFillFrames: gapFillFrames, gapCount: gapCount,
                         overlapDroppedFrames: overlapDroppedFrames, maxAbsDriftSeconds: maxAbsDriftSeconds)
    }

    /// Record what the writer actually did. Keeps all diagnostics in one place.
    public mutating func commit(_ placement: Placement, chunkHostSeconds: Double, frameCount: Int) {
        let d = drift(chunkHostSeconds: chunkHostSeconds)
        maxAbsDriftSeconds = max(maxAbsDriftSeconds, abs(d))
        switch placement {
        case .append:
            framesPlaced += Int64(frameCount); lastDrift = d
        case let .padSilence(frames):
            gapFillFrames += Int64(frames); gapCount += 1; framesPlaced += Int64(frames + frameCount)
            lastDrift = d - Double(frames) / sampleRate
        case let .dropLeading(frames):
            overlapDroppedFrames += Int64(frames); framesPlaced += Int64(frameCount - frames)
            lastDrift = d + Double(frames) / sampleRate
        }
    }
}
