import AVFoundation
import Foundation
import Testing
@testable import InterviewRecorderSpike

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
