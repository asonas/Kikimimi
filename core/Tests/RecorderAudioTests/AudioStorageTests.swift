import AVFoundation
import Foundation
import RecorderCore
import Testing
@testable import RecorderAudio

private func folder() throws -> SessionFolder {
    let folder = SessionFolder(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    return folder
}

private func sine(rate: Double, seconds: Double = 1) -> [Float] {
    (0..<Int(rate * seconds)).map { Float(pow(10, -6.0 / 20) * sin(Double($0) * 2 * .pi * 440 / rate)) }
}

private func spool(_ url: URL, rate: Double = 48_000) throws {
    var writer = try SpoolWriter(url: url, sampleRate: rate)
    try writer.append(sine(rate: rate))
    writer.close()
}

private func readPCM(_ url: URL) throws -> [Int16] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
    var result: [Int16] = []
    while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
        guard buffer.frameLength > 0 else { break }
        result += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    }
    return result
}

@Test func spoolClampsRoundsAndWritesInt16MonoAtSourceRate() throws {
    let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    var writer = try SpoolWriter(url: folder.spool(.me), sampleRate: 96_000)
    try writer.append([-2, -1, -0.5, -1.5 / 32768, -0.5 / 32768, 0, 0.5 / 32768, 1.5 / 32768, 0.5, 1, 2, .nan])
    writer.close()
    #expect(try readPCM(folder.spool(.me)) == [-32768, -32768, -16384, -2, -1, 0, 1, 2, 16384, 32767, 32767, 0])
    let file = try AVAudioFile(forReading: folder.spool(.me))
    #expect(file.fileFormat.sampleRate == 96_000)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.fileFormat.streamDescription.pointee.mBitsPerChannel == 16)
}

@Test func spoolInsertsSilenceAcrossFiveSecondSyncBoundary() throws {
    let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    var writer = try SpoolWriter(url: folder.spool(.me), sampleRate: 48_000)
    try writer.append([0.5])
    try writer.appendSilence(frames: 48_000 * 6 + 17)
    try writer.append([-0.5])
    writer.close()
    let pcm = try readPCM(folder.spool(.me))
    #expect(pcm.count == 48_000 * 6 + 19)
    #expect(pcm.first == 16384)
    #expect(pcm.last == -16384)
    #expect(pcm.dropFirst().dropLast().allSatisfy { $0 == 0 })
}

@Test func spoolSurvivesTruncatedTail() throws {
    let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    // Copy an open CAF, whose unclosed data-size header models SIGKILL.
    var writer = try SpoolWriter(url: folder.spool(.me), sampleRate: 48_000)
    try writer.append(sine(rate: 48_000, seconds: 6))
    for removed in [1, 3, 101, 2049] {
        let copy = folder.url.appendingPathComponent("truncated-\(removed).caf")
        try FileManager.default.copyItem(at: folder.spool(.me), to: copy)
        let handle = try FileHandle(forUpdating: copy)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - UInt64(removed)); try handle.close()
        let file = try AVAudioFile(forReading: copy)
        let pcm = try readPCM(copy)
        #expect(pcm.count == Int(file.length))
        #expect(pcm.count > 48_000 * 5)
    }
    writer.close()
}

@Test func aacFinalizerConverts96kHzTo48kHzAndMeasuresPeak() async throws {
    let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    try spool(folder.spool(.me), rate: 96_000)
    let result = try await AACFinalizer().finalize(folder, clockTolerance: 0.1)
    let audio = try #require(result.tracks.me)
    #expect(audio.sampleRate == 48_000)
    #expect(abs(audio.frames - 48_000) <= 2048)
    #expect(abs(audio.peakDBFS - -6) < 0.5)
    #expect(!FileManager.default.fileExists(atPath: folder.spool(.me).path))
    #expect(!FileManager.default.fileExists(atPath: folder.audioPart(.me).path))
    let repeated = try await AACFinalizer().finalize(folder, clockTolerance: 0.1)
    #expect(repeated == result)
}

@Test func aacFinalizerStateMatrixAndIdempotency() async throws {
    for scenario in ["spool", "spool-part", "spool-final", "final", "none"] {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder.url) }
        if scenario == "spool-final" || scenario == "final" {
            try spool(folder.spool(.remote))
            _ = try await AACFinalizer().finalize(folder, clockTolerance: 0.1)
        }
        if scenario.contains("spool") { try spool(folder.spool(.remote)) }
        if scenario == "spool-part" { try Data("incomplete".utf8).write(to: folder.audioPart(.remote)) }
        let before = try? Data(contentsOf: folder.audio(.remote))
        let first = try await AACFinalizer().finalize(folder, clockTolerance: 0.1)
        let second = try await AACFinalizer().finalize(folder, clockTolerance: 0.1)
        #expect(first == second)
        if scenario == "none" { #expect(first.tracks == .init()) }
        else {
            #expect(first.tracks.remote?.sampleRate == 48_000)
            #expect(abs((first.tracks.remote?.frames ?? 0) - 48_000) <= 2048)
            if let before { #expect(try Data(contentsOf: folder.audio(.remote)) == before) }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.spool(.remote).path))
        #expect(!FileManager.default.fileExists(atPath: folder.audioPart(.remote).path))
    }
}

@Test func aacFinalizerPreserves44100RateAndHandlesSilentTrack() async throws {
    let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    try spool(folder.spool(.me), rate: 44_100)
    var writer = try SpoolWriter(url: folder.spool(.remote), sampleRate: 48_000)
    try writer.appendSilence(frames: 48_000); writer.close()
    let result = try await AACFinalizer().finalize(folder, clockTolerance: 0.1)
    #expect(result.tracks.me?.sampleRate == 44_100)
    #expect(abs((result.tracks.me?.frames ?? 0) - 44_100) <= 2048)
    #expect(result.tracks.remote?.isEffectivelySilent == true)
}

@Test func aacFinalizerRepairsOddTruncatedSpoolTail() async throws {
    let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    try spool(folder.spool(.me))
    let handle = try FileHandle(forUpdating: folder.spool(.me))
    let size = try handle.seekToEnd()
    try handle.truncate(atOffset: size - 101); try handle.close()
    let result = try await AACFinalizer().finalize(folder, clockTolerance: 0.1)
    #expect(abs((result.tracks.me?.frames ?? 0) - (48_000 - 51)) <= 2048)
}

@Test func aacFinalizerRejectsCorruptFinalWithoutDeletingSpool() async throws {
    let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    try spool(folder.spool(.me))
    try Data("truncated AAC".utf8).write(to: folder.audio(.me))
    await #expect(throws: (any Error).self) { try await AACFinalizer().finalize(folder, clockTolerance: 0.1) }
    #expect(FileManager.default.fileExists(atPath: folder.spool(.me).path))
}

@Test func aacVerificationRejectsShortEncodeAndTruncatedContainer() async throws {
    let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    var writer = try SpoolWriter(url: folder.spool(.me), sampleRate: 48_000)
    try writer.append(sine(rate: 48_000, seconds: 0.1)); writer.close()
    let finalizer = AACFinalizer()
    _ = try await finalizer.finalize(folder, clockTolerance: 0.1)
    // A decodable but prematurely ended encode must fail the expected-frame check.
    #expect(throws: CocoaError.self) {
        try finalizer.verify(url: folder.audio(.me), expectedFrames: 48_000)
    }
    let handle = try FileHandle(forUpdating: folder.audio(.me))
    try handle.truncate(atOffset: 32); try handle.close()
    #expect(throws: (any Error).self) {
        try finalizer.verify(url: folder.audio(.me), expectedFrames: 4800)
    }
}
