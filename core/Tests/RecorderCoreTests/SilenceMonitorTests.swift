import Testing
@testable import RecorderCore

@Test func silenceMonitorWaitsThenBecomesSilentAtTwentySeconds() {
    var monitor = SilenceMonitor()
    #expect(monitor.ingest(.me, peakDBFS: -75, at: 100) == nil)
    #expect(monitor.ingest(.me, peakDBFS: -.infinity, at: 119.999) == nil)
    #expect(monitor.ingest(.me, peakDBFS: -75, at: 120) == .silent)
    #expect(monitor.ingest(.me, peakDBFS: -80, at: 121) == nil)
}

@Test func silenceMonitorLiveSilentAndRecoveryTransitions() {
    var monitor = SilenceMonitor()
    #expect(monitor.ingest(.remote, peakDBFS: -74.999, at: 0) == .live)
    #expect(monitor.ingest(.remote, peakDBFS: -20, at: 5) == nil)
    #expect(monitor.ingest(.remote, peakDBFS: -75, at: 24.999) == nil)
    #expect(monitor.ingest(.remote, peakDBFS: -80, at: 25) == .silent)
    #expect(monitor.ingest(.remote, peakDBFS: -74, at: 26) == .live)
    #expect(monitor.ingest(.remote, peakDBFS: -76, at: 45.999) == nil)
    #expect(monitor.ingest(.remote, peakDBFS: -76, at: 46) == .silent)
}

@Test func silenceMonitorDigitalOverridesLiveAndSilentWithoutRepeatedEvents() {
    var monitor = SilenceMonitor()
    #expect(monitor.ingest(.me, peakDBFS: -20, at: 0) == .live)
    #expect(monitor.digitalSilence(.me, active: true) == .digitallySilent)
    #expect(monitor.digitalSilence(.me, active: true) == nil)
    #expect(monitor.ingest(.me, peakDBFS: -90, at: 20) == nil)
    #expect(monitor.digitalSilence(.me, active: false) == .silent)
    #expect(monitor.digitalSilence(.me, active: false) == nil)
    #expect(monitor.digitalSilence(.me, active: true) == .digitallySilent)
    #expect(monitor.ingest(.me, peakDBFS: -20, at: 21) == nil)
    #expect(monitor.digitalSilence(.me, active: false) == .live)
}

@Test func silenceMonitorDigitalClearsToWaitingAndTracksStayIndependent() {
    var monitor = SilenceMonitor()
    #expect(monitor.digitalSilence(.me, active: false) == nil)
    #expect(monitor.digitalSilence(.me, active: true) == .digitallySilent)
    #expect(monitor.digitalSilence(.me, active: false) == .waitingForAudio)
    #expect(monitor.ingest(.me, peakDBFS: -90, at: 0) == nil)
    #expect(monitor.ingest(.remote, peakDBFS: -10, at: 19) == .live)
    #expect(monitor.ingest(.me, peakDBFS: -90, at: 20) == .silent)
    #expect(monitor.ingest(.remote, peakDBFS: -90, at: 20) == nil)
}

@Test func silenceMonitorIgnoresInvalidLevelsAndTimes() {
    var monitor = SilenceMonitor()
    #expect(monitor.ingest(.me, peakDBFS: .nan, at: 0) == nil)
    #expect(monitor.ingest(.me, peakDBFS: -20, at: .nan) == nil)
    #expect(monitor.ingest(.me, peakDBFS: -20, at: .infinity) == nil)
    #expect(monitor.ingest(.me, peakDBFS: -20, at: 0) == .live)
}
