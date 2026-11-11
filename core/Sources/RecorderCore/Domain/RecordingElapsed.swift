import Foundation

public enum RecordingElapsed {
    public static func string(startedAt: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(startedAt)
        guard interval.isFinite, interval < Double(Int.max) else { return "00:00:00" }
        let seconds = Int(max(0, interval))
        return String(format: "%02ld:%02ld:%02ld", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}
