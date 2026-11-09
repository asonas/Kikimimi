import AVFoundation
import Foundation
import Testing
@testable import InterviewRecorderSpike

@Test func selectsInputDevice() throws {
    let devices = [InputDevice(id: 1, name: "Rubix44", uid: "rubix-uid", channels: 4, isDefault: false),
        InputDevice(id: 2, name: "Mac microphone", uid: "mac-uid", channels: 1, isDefault: true),
        InputDevice(id: 3, name: "Rubix44 extra", uid: "extra-uid", channels: 2, isDefault: false)]
    #expect(try selectInputDevice(nil, from: devices).id == 2)
    #expect(try selectInputDevice("rubix-uid", from: devices).id == 1)
    #expect(try selectInputDevice("Rubix44", from: devices).id == 1)
    #expect(try selectInputDevice("microphone", from: devices).id == 2)
    #expect(throws: (any Error).self) { try selectInputDevice("Rubix", from: devices) }
    #expect(throws: (any Error).self) { try selectInputDevice("missing", from: devices) }
}

@Test(arguments: [false, true]) func extractsOnlySelectedPCMChannel(interleaved: Bool) throws {
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000, interleaved: interleaved, channelLayout: layout)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
    buffer.frameLength = 8
    let samples = try #require(buffer.floatChannelData)
    for channel in 0..<4 {
        for frame in 0..<8 {
            samples[interleaved ? 0 : channel][interleaved ? frame * 4 + channel : frame] = Float(channel * 10 + frame)
        }
    }
    for channel in 1...4 {
        let mono = try extractChannel(buffer, channel: channel)
        #expect(mono.format.channelCount == 1)
        #expect(mono.frameLength == 8)
        let result = try #require(mono.floatChannelData)
        for frame in 0..<8 { #expect(result[0][frame] == Float((channel - 1) * 10 + frame)) }
    }
    #expect(throws: (any Error).self) { try extractChannel(buffer, channel: 0) }
    #expect(throws: (any Error).self) { try extractChannel(buffer, channel: 5) }
}

@Test func parsesInputOptionsAndEncodesUnspecifiedChannel() throws {
    let options = try Options(["--input-device", "Rubix44", "--input-channel", "1", "--list-input-devices"])
    #expect(options.inputDevice == "Rubix44")
    #expect(options.inputChannel == 1)
    #expect(options.listInputDevices)
    for value in ["0", "-1", "x"] {
        #expect(throws: (any Error).self) { try Options(["--input-channel", value]) }
    }
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(TrackMetadata())) as? [String: Any])
    #expect(json["inputChannel"] is NSNull)
}

@Test func rejectsInvalidArguments() {
    for arguments in [["--duration", "nan"], ["--duration", "0"], ["--duration"], ["--bad", "x"]] {
        #expect(throws: (any Error).self) { try Options(arguments) }
    }
}

@Test func parsesIgnorePreflightWithoutValue() throws {
    let options = try Options(["--ignore-preflight", "--app", "com.google.Chrome", "--duration", "5"])
    #expect(options.ignorePreflight)
    #expect(options.app == "com.google.Chrome")
    #expect(options.duration == 5)
    #expect(try Options(["--ignore-preflight"]).ignorePreflight)
    #expect(try !Options([]).ignorePreflight)
}

@Test func writesAndFinalizesMonoAACWithFirstTimestamp() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("audio.m4a")
    let sink = AudioSink(url: url)
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    buffer.frameLength = 4800
    let channels = try #require(buffer.floatChannelData)
    for index in 0..<4800 {
        channels[0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.2
        channels[1][index] = channels[0][index]
    }
    for index in 0..<10 { sink.append(buffer, hostSeconds: 123 + Double(index) * 0.1) }
    let (metadata, failure) = sink.close()
    #expect(failure == nil)
    #expect(metadata.firstSampleHostTimeSeconds == 123)
    #expect(metadata.frames == 48_000)
    #expect(metadata.sourceChannels == 2)
    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
    #expect(file.length > 0)
    let decoded = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800))
    try file.read(into: decoded)
    #expect(decoded.frameLength > 0)
    #expect(try #require(decoded.floatChannelData)[0][100] != 0)
}
