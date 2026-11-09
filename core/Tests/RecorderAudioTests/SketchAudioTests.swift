import Testing
@testable import RecorderAudio

// Real tests still to write (see design.md "Test plan"):
//  - SpoolWriter: float->int16 clamp, silence insertion, truncated-tail reopen (simulates SIGKILL mid-write)
//  - AACFinalizer: idempotency across {spool}, {spool+.part}, {spool+m4a}, {m4a}; frame-count tolerance; a 96 kHz spool
//    encodes to a 48 kHz m4a with frames ~ spoolFrames / 2
//  - extractChannel (ported from the spike)
@Test(.disabled("not implemented")) func spoolSurvivesTruncatedTail() {}

@Test func aacOutputRateIsCappedAt48kHz() {
    #expect(AACFinalizer.outputSampleRate(forSpoolRate: 44_100) == 44_100)
    #expect(AACFinalizer.outputSampleRate(forSpoolRate: 48_000) == 48_000)
    #expect(AACFinalizer.outputSampleRate(forSpoolRate: 96_000) == 48_000)
    #expect(AACFinalizer.outputSampleRate(forSpoolRate: 192_000) == 48_000)
}
