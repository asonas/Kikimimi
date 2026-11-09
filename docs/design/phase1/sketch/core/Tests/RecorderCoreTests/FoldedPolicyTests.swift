import Foundation
import Testing
@testable import RecorderCore

// Executable spec for the pure pieces folded in from candidate A: digital-silence detection, session-level transcription
// progress, and launch-argument parsing for the DEBUG headless mode and relaunch.

// MARK: - DigitalSilenceDetector

private let zeros100ms = [Float](repeating: 0, count: 4_800)    // 48 kHz

@Test func digitalSilenceFiresOnceAtThreeSecondsOfExactZeros() {
    var d = DigitalSilenceDetector(sampleRate: 48_000)
    for _ in 0..<29 { #expect(d.ingest(zeros100ms) == nil) }       // 2.9 s: not yet
    #expect(d.ingest(zeros100ms) == true)                           // 3.0 s: fires
    #expect(d.ingest(zeros100ms) == nil)                            // stays active, no repeat emission
    #expect(d.isActive)
}

@Test func digitalSilenceClearsOnTheFirstNonZeroSampleAndRestartsTheRun() {
    var d = DigitalSilenceDetector(sampleRate: 1_000)                // 3_000 frames
    #expect(d.ingest([Float](repeating: 0, count: 3_000)) == true)
    #expect(d.ingest([0, 0, 0.001, 0]) == false)
    #expect(d.zeroRunFrames == 1)                                   // the run restarts after the non-zero sample
    #expect(d.ingest([Float](repeating: 0, count: 2_998)) == nil)   // 2_999: one short
    #expect(d.ingest([-0.0]) == true)                               // negative zero is still digital silence
}

@Test func aRealNoiseFloorIsNeverDigitalSilence() {
    var d = DigitalSilenceDetector(sampleRate: 1_000)
    let floor = (0..<10_000).map { i in Float(i % 2 == 0 ? 1e-7 : -1e-7) }   // ~ -140 dBFS, but not exact zeros
    #expect(d.ingest(floor) == nil)
    #expect(!d.isActive)
}

@Test func onlyTheSelfTrackIsWatched() {
    #expect(DigitalSilenceDetector.forTrack(.me, sampleRate: 48_000) != nil)
    #expect(DigitalSilenceDetector.forTrack(.remote, sampleRate: 48_000) == nil)
}

// MARK: - TranscriptionProgress

@Test func progressIsWeightedByDurationAndIndependentOfTrackOrder() {
    var p = TranscriptionProgress(durations: PerTrack(me: 30, remote: 90))
    #expect(p.fraction == 0)
    #expect(p.update(.remote, fraction: 1) == 0.75)
    #expect(p.update(.me, fraction: 0.5) == 0.875)
    #expect(p.update(.me, fraction: 1) == 1)

    var q = TranscriptionProgress(durations: PerTrack(me: 30, remote: 90))
    q.update(.me, fraction: 1)                                       // other order, same weights
    #expect(q.fraction == 0.25)
}

@Test func progressIsMonotoneAndIgnoresGarbage() {
    var p = TranscriptionProgress(durations: PerTrack(remote: 60))  // self skipped by Core (silent / no audio)
    #expect(p.update(.remote, fraction: 0.6) == 0.6)
    #expect(p.update(.remote, fraction: 0.4) == 0.6)                // backwards: ignored
    #expect(p.update(.remote, fraction: .nan) == 0.6)
    #expect(p.update(.me, fraction: 1) == 0.6)                      // not requested: ignored
    #expect(p.update(.remote, fraction: 7) == 1)                    // clamped
}

@Test func zeroDurationTracksAreWeighedEqually() {
    var p = TranscriptionProgress(durations: PerTrack(me: 0, remote: 0))
    #expect(p.update(.remote, fraction: 1) == 0.5)
    #expect(TranscriptionProgress(durations: PerTrack()).fraction == 0)
}

// MARK: - LaunchMode / HeadlessCommand

@Test func launchModeIgnoresSystemArgumentsAndDetectsRelaunch() throws {
    #expect(try LaunchMode.parse(["/Applications/InterviewRecorder.app/Contents/MacOS/InterviewRecorder"]) == .normal)
    #expect(try LaunchMode.parse(["bin", "-NSDocumentRevisionsDebugMode", "YES"]) == .normal)
    #expect(try LaunchMode.parse(["bin", "--relaunch"]) == .relaunched)
    #expect(LaunchMode.relaunched.skipsSingleInstanceCheck)
    #expect(!LaunchMode.normal.skipsSingleInstanceCheck)
}

@Test func headlessRecordParsesIntoTheSameDraftTheUIBuilds() throws {
    let mode = try LaunchMode.parse(["bin", "-NSDocumentRevisionsDebugMode", "YES", "--headless", "record",
                                     "--seconds", "30", "--company", "smoke", "--target", "com.google.Chrome", "--title", "QA"])
    #expect(mode == .headless(.record(SessionDraft(company: "smoke", title: "QA",
                                                   remote: .app(bundleID: "com.google.Chrome", name: "com.google.Chrome")),
                                      seconds: 30)))
    #expect(mode.skipsSingleInstanceCheck)
    #expect(try HeadlessCommand.parse(["record", "--target", "all", "--company", "x", "--seconds", "1.5"])
            == .record(SessionDraft(company: "x", remote: .allSystemAudio), seconds: 1.5))
}

@Test func headlessTranscribeTakesTheSessionID() throws {
    let id = UUID()
    #expect(try HeadlessCommand.parse(["transcribe", id.uuidString]) == .transcribe(sessionID: id))
}

@Test func headlessRejectsMalformedArguments() {
    #expect(throws: LaunchArgumentError.missingSubcommand) { try HeadlessCommand.parse([]) }
    #expect(throws: LaunchArgumentError.unknownSubcommand("play")) { try HeadlessCommand.parse(["play"]) }
    #expect(throws: LaunchArgumentError.missingValue("--target")) {
        try HeadlessCommand.parse(["record", "--seconds", "3", "--company", "x"])
    }
    #expect(throws: LaunchArgumentError.invalidValue("--seconds", "-1")) {
        try HeadlessCommand.parse(["record", "--seconds", "-1", "--company", "x", "--target", "all"])
    }
    #expect(throws: LaunchArgumentError.missingValue("--company")) {
        try HeadlessCommand.parse(["record", "--seconds", "3", "--company", "--target", "all"])
    }
    #expect(throws: LaunchArgumentError.unknownArgument("--mic")) {
        try HeadlessCommand.parse(["record", "--mic", "x"])
    }
    #expect(throws: LaunchArgumentError.invalidValue("<session-id>", "abc")) { try HeadlessCommand.parse(["transcribe", "abc"]) }
}
