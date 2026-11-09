import AVFoundation
import Foundation

// Usage:
//   swift crash.swift write <kind> <path>   -> writes ~3 s of sine, then SIGKILLs itself without closing
//   swift crash.swift read <path>           -> opens with AVAudioFile and reports length
// kind: m4a | caf-aac | caf-pcm | wav

let args = CommandLine.arguments
let mode = args[1]

func settings(for kind: String) -> [String: Any] {
    switch kind {
    case "m4a", "caf-aac":
        return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
    default:
        return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    }
}

if mode == "write" {
    let kind = args[2]
    let url = URL(fileURLWithPath: args[3])
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: settings(for: kind),
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    buffer.frameLength = 4800
    var phase = 0.0
    for _ in 0..<30 {
        for i in 0..<4800 {
            buffer.floatChannelData![0][i] = Float(sin(phase)) * 0.2
            phase += 2 * .pi * 440 / 48_000
        }
        try file.write(from: buffer)
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    FileHandle.standardError.write(Data("wrote 144000 frames, size on disk before kill: \(size)\n".utf8))
    kill(getpid(), SIGKILL)
} else {
    let url = URL(fileURLWithPath: args[2])
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    do {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(file.length, 1)))!
        try file.read(into: buffer)
        print("\(url.lastPathComponent): size=\(size) OPEN OK length=\(file.length) decoded=\(buffer.frameLength)")
    } catch {
        print("\(url.lastPathComponent): size=\(size) OPEN FAILED \(error)")
    }
}
