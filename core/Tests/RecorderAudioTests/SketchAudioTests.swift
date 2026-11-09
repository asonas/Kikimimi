import Testing
@testable import RecorderAudio

// Storage behavior tests live in AudioStorageTests. Channel extraction is a later capture commit.

@Test func aacOutputRateIsCappedAt48kHz() {
    #expect(AACFinalizer.outputSampleRate(forSpoolRate: 44_100) == 44_100)
    #expect(AACFinalizer.outputSampleRate(forSpoolRate: 48_000) == 48_000)
    #expect(AACFinalizer.outputSampleRate(forSpoolRate: 96_000) == 48_000)
    #expect(AACFinalizer.outputSampleRate(forSpoolRate: 192_000) == 48_000)
}
