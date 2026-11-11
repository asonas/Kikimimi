import Foundation

/// Display mapping only; capture cadence and health remain independent of the UI.
public enum LevelMeterScale {
    public static let segmentCount = 30
    public enum Band: Sendable, Equatable { case green, amber, red }

    public static func litSegments(dbFS: Float?) -> Int {
        guard let dbFS, dbFS.isFinite else { return 0 }
        return Int(min(30, max(0, (dbFS + 60) / 2)))
    }
    public static func band(segment: Int) -> Band {
        let upperDBFS = -60 + (segment + 1) * 2
        if upperDBFS >= -3 { return .red }
        if upperDBFS >= -12 { return .amber }
        return .green
    }
    public static func position(dbFS: Float) -> Double {
        guard dbFS.isFinite else { return 0 }
        return Double(min(1, max(0, (dbFS + 60) / 60)))
    }
    public static func valueText(dbFS: Float?) -> String {
        guard let dbFS, dbFS.isFinite, dbFS > -120 else { return "−∞ dBFS" }
        let value = Int(min(0, dbFS).rounded())
        return value < 0 ? "−\(abs(value)) dBFS" : "0 dBFS"
    }
}
