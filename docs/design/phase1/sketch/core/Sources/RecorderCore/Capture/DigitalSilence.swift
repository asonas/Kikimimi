import Foundation

/// Pure. Detects a mic that delivers digital silence (every sample exactly 0.0), which Phase 0 observed from the built-in
/// mic in clamshell mode for a whole session without any error. A real mic has a noise floor and never produces a run of
/// exact zeros, so 3 s of them is a device problem, not a quiet speaker. This warns within seconds instead of the 20 s
/// level-based `SilenceMonitor`.
///
/// Feed it SOURCE samples only, i.e. what the device delivered, BEFORE `TrackClock` pads gaps with zeros. Padded frames
/// are not audio from the device; counting them would raise a false warning on every gap fill. A gap therefore neither
/// extends nor resets a zero run.
public struct DigitalSilenceDetector: Sendable, Equatable {
    /// Run length of exact zeros that counts as digital silence.
    public static let defaultWindowSeconds = 3.0

    public let thresholdFrames: Int
    public private(set) var zeroRunFrames = 0
    public private(set) var isActive = false

    public init(sampleRate: Double, windowSeconds: Double = DigitalSilenceDetector.defaultWindowSeconds) {
        thresholdFrames = max(1, Int((sampleRate * windowSeconds).rounded()))
    }

    /// The policy for which tracks are watched: only `self`. The remote track is legitimately all zeros while nobody
    /// talks (and SCStream may deliver exact silence), so watching it would only produce noise. nil = not watched.
    public static func forTrack(_ track: Track, sampleRate: Double) -> DigitalSilenceDetector? {
        track == .me ? DigitalSilenceDetector(sampleRate: sampleRate) : nil
    }

    /// Consumes one source chunk. Returns the new `isActive` when it changed during this chunk, else nil.
    /// Becomes active when the current run of consecutive exact zeros reaches `thresholdFrames`;
    /// clears on the first non-zero sample.
    public mutating func ingest(_ samples: [Float]) -> Bool? {
        let before = isActive
        for s in samples {
            if s == 0 {                                  // -0.0 == 0.0 too
                zeroRunFrames += 1
                if zeroRunFrames >= thresholdFrames { isActive = true }
            } else {
                zeroRunFrames = 0
                isActive = false
            }
        }
        return isActive == before ? nil : isActive
    }
}
