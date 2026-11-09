import AVFoundation
import Foundation
import RecorderCore
import Testing
@testable import RecorderAudio

@Test(arguments: [false, true]) func microphoneExtractsOnlySelectedChannel(interleaved: Bool) throws {
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                              interleaved: interleaved, channelLayout: layout)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
    buffer.frameLength = 8
    let samples = try #require(buffer.floatChannelData)
    for channel in 0..<4 {
        for frame in 0..<8 { samples[interleaved ? 0 : channel][interleaved ? frame * 4 + channel : frame] = Float(channel * 10 + frame) }
    }
    for channel in 1...4 {
        #expect(try monoSamples(buffer, channel: channel) == (0..<8).map { Float((channel - 1) * 10 + $0) })
    }
    #expect(try monoSamples(buffer, channel: nil) == (0..<8).map { Float(15 + $0) })
    #expect(throws: AudioSourceFailure.self) { try monoSamples(buffer, channel: 0) }
    #expect(throws: AudioSourceFailure.self) { try monoSamples(buffer, channel: 5) }
}

@Test func microphoneRejectsUnsupportedPCMFormat() throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
    buffer.frameLength = 1
    #expect(throws: AudioSourceFailure.self) { try monoSamples(buffer, channel: 1) }
}

@Test func inputDeviceEnumerationHasUIDsAndPositiveChannelCounts() throws {
    let devices = try CoreAudioInputDevices().inputDevices()
    #expect(Set(devices.map(\.uid)).count == devices.count)
    for device in devices {
        #expect(!device.uid.isEmpty)
        #expect(!device.name.isEmpty)
        #expect(device.inputChannels > 0)
    }
}

private struct FailedDeviceSource: AudioSource {
    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        throw AudioSourceFailure(code: .deviceLost, message: "Selected microphone was disconnected")
    }
    func stop() async {}
}

@Test func trackRecorderPreservesDeviceLostFromMicrophoneSource() async throws {
    let events = AsyncStream<CaptureEvent>.makeStream()
    let folder = SessionFolder(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let recorder = TrackRecorder(track: .me, source: FailedDeviceSource(), folder: folder,
        willWriteFirstSample: { _, _ in Issue.record("source failed before anchor") }, emit: { events.continuation.yield($0) })
    await recorder.run()
    events.continuation.finish()
    var failures: [TrackFailure] = []
    for await event in events.stream { if case .trackFailed(_, let failure) = event { failures.append(failure) } }
    #expect(failures.count == 1)
    #expect(failures.first?.code == .deviceLost)
    #expect(!FileManager.default.fileExists(atPath: folder.spool(.me).path))
}
