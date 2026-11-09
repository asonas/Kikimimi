import AVFoundation
import Foundation

// Usage: aacrate <sampleRate> <outdir>
// Writes 1 s of sine as CAF LPCM16 at the rate, then transcodes it to AAC m4a (mono, 64 kbps, same rate)
// with AVAudioFile, and reports success and lengths.

let rate = Double(CommandLine.arguments[1])!
let dir = URL(fileURLWithPath: CommandLine.arguments[2])
let caf = dir.appendingPathComponent("j-\(Int(rate)).caf")
let m4a = dir.appendingPathComponent("a-\(Int(rate)).m4a")
try? FileManager.default.removeItem(at: caf)
try? FileManager.default.removeItem(at: m4a)

let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
do {
    let journal = try AVAudioFile(forWriting: caf, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / rate)) * 0.2 }
    try journal.write(from: buffer)
}
do {
    let input = try AVAudioFile(forReading: caf)
    let output = try AVAudioFile(forWriting: m4a, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
    while input.framePosition < input.length {
        try input.read(into: chunk)
        try output.write(from: chunk)
    }
    let journalLength = input.length
    _ = output // release closes the file at scope end
    print("rate=\(Int(rate)) journal=\(journalLength)", terminator: " ")
}
do {
    let check = try AVAudioFile(forReading: m4a)
    print("m4a OK length=\(check.length) fileRate=\(check.fileFormat.sampleRate)")
} catch {
    print("m4a FAILED \(error)")
}
