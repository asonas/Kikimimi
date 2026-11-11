import Foundation

public struct MeterSample: Sendable, Equatable {
    public let dbFS: Float
    /// Monotonic receipt time, shared with the display clock (not the audio timeline).
    public let at: TimeInterval
    public init(dbFS: Float, at: TimeInterval) { self.dbFS = dbFS; self.at = at }
}

public struct MeterReading: Sendable, Equatable {
    public enum State: Sendable, Equatable { case unmeasured, silent, live, inputLost }
    public let level: Float
    public let peak: Float?
    public let state: State
    public var valueText: String {
        switch state {
        case .unmeasured, .silent: "−∞ dBFS"
        case .inputLost: "入力停止"
        case .live: LevelMeterScale.valueText(dbFS: level)
        }
    }
}

public struct MeterBallistics: Sendable {
    private var level: Float = -60
    private var peak: Float = -60
    private var holdUntil: TimeInterval = 0
    private var lastFrame: TimeInterval?
    public init() {}

    public mutating func frame(dbFS: Float?, at now: TimeInterval, reducedMotion: Bool, stale: Bool) -> MeterReading {
        if stale {
            self = Self()
            return MeterReading(level: -60, peak: nil, state: .inputLost)
        }
        let time = now.isFinite ? now : (lastFrame ?? 0)
        let dt = lastFrame.map { min(0.1, max(0, time - $0)) } ?? 0
        lastFrame = time
        let measured = dbFS?.isFinite == true
        let value = measured ? min(0, max(-60, dbFS!)) : -60
        level = reducedMotion ? value : max(value, level - Float(24 * dt))
        if value >= peak { peak = value; holdUntil = time + 0.8 }
        else if time > holdUntil { peak = max(level, peak - Float(24 * dt)) }
        let state: MeterReading.State = !measured ? .unmeasured : (level > -60 ? .live : .silent)
        return MeterReading(level: level, peak: peak > -60 ? peak : nil, state: state)
    }
}
