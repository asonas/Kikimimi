// Measures: CAF int16 mono 48 kHz spool -> AAC 64 kbps m4a encode speed (stop-time cost), and file sizes.
// Usage: encode-speed <minutes> <dir>
import AVFoundation
import Foundation

let minutes = Double(CommandLine.arguments[1])!
let dir = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let spool = dir.appendingPathComponent("spool.caf"), out = dir.appendingPathComponent("out.m4a")
try? FileManager.default.removeItem(at: spool); try? FileManager.default.removeItem(at: out)
let rate = 48_000.0
let float = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
let totalSeconds = Int(minutes * 60)

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

// 1. Write the spool (speech-like: modulated tones + noise) faster than real time.
var t0 = now()
do {
    let file = try AVAudioFile(forWriting: spool, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
        commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: float, frameCapacity: AVAudioFrameCount(rate))!
    var phase = 0.0
    for s in 0..<totalSeconds {
        buf.frameLength = AVAudioFrameCount(rate)
        let p = buf.floatChannelData![0]
        let f = 120.0 + Double((s * 37) % 200)
        for i in 0..<Int(rate) {
            let env = 0.5 + 0.5 * sin(Double(i) * 2 * .pi * 3 / rate)
            p[i] = Float(sin(phase) * 0.25 * env + Double.random(in: -0.02...0.02)); phase += 2 * .pi * f / rate
        }
        try file.write(from: buf)
    }
}
print("spool written in \(String(format: "%.1f", now() - t0)) s, size \((try FileManager.default.attributesOfItem(atPath: spool.path)[.size] as! NSNumber).int64Value / 1_000_000) MB for \(minutes) min")

// 2. Encode spool -> m4a (the finalize step)
t0 = now()
do {
    let input = try AVAudioFile(forReading: spool)
    let output = try AVAudioFile(forWriting: out, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000], commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(rate))!
    var peak: Float = 0
    while input.framePosition < input.length {
        try input.read(into: buf, frameCount: AVAudioFrameCount(rate))
        let p = buf.floatChannelData![0]
        for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(p[i])) }
        try output.write(from: buf)
    }
}
let dt = now() - t0
print("encode took \(String(format: "%.1f", dt)) s = \(String(format: "%.0f", Double(totalSeconds) / dt))x realtime, m4a \((try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! NSNumber).int64Value / 1_000_000) MB")
let check = try AVAudioFile(forReading: out)
print("reopen m4a: \(check.length) frames (spool \(totalSeconds * 48_000)), diff \(check.length - Int64(totalSeconds * 48_000))")
