import Foundation
import Testing
@testable import RecorderCore

@Test func recordingElapsedKeepsHoursAndClampsClockReversal() {
    let start = Date(timeIntervalSince1970: 1000)
    for (seconds, expected) in [(-5.0, "00:00:00"), (0, "00:00:00"), (758.9, "00:12:38"),
                                (3600, "01:00:00"), (90061, "25:01:01")] {
        #expect(RecordingElapsed.string(startedAt: start, now: start.addingTimeInterval(seconds)) == expected)
    }
}
