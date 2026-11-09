// Crash-safety probe: which container survives `kill -9` while still being written?
// Usage:
//   probe write <m4a|caf16|cafaac|wav16> <path>   writes 48 kHz mono sine, 100 ms per chunk, up to 10 s
//   probe read <path>                             prints decodable frame count or the error
import AVFoundation
import Foundation

func settings(for mode: String) -> [String: Any] {
    switch mode {
    case "m4a", "cafaac":
        return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
    case "caf16", "wav16":
        return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false]
    default:
        fatalError("unknown mode")
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage"); exit(2) }

if args[1] == "write" {
    let mode = args[2]
    let url = URL(fileURLWithPath: args[3])
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: settings(for: mode),
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    var phase = 0.0
    var written = 0
    for _ in 0..<100 {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        let p = buffer.floatChannelData![0]
        for i in 0..<4800 { p[i] = Float(sin(phase)) * 0.3; phase += 2 * .pi * 440 / 48_000 }
        try file.write(from: buffer)
        written += 4800
        print("written \(written)")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 0.1)
    }
    print("clean exit (file not explicitly closed before process end)")
} else if args[1] == "read" {
    let url = URL(fileURLWithPath: args[2])
    do {
        let file = try AVAudioFile(forReading: url)
        print("OK length=\(file.length) frames rate=\(file.processingFormat.sampleRate) bytes=\((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) ?? "?")")
        // Decode everything to make sure it is really readable, not just the header.
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        var total = 0
        while true {
            do { try file.read(into: buffer, frameCount: 48_000) } catch { print("read error after \(total): \(error)"); break }
            if buffer.frameLength == 0 { break }
            total += Int(buffer.frameLength)
        }
        print("decoded \(total) frames")
    } catch {
        print("FAIL open: \(error)")
    }
}
