import AVFoundation
import CoreAudio
import CoreGraphics
import ScreenCaptureKit
import Foundation
import Security

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func logDiagnosticError(_ operation: String, _ error: any Error) {
    let error = error as NSError
    log("[DEBUG-task03] \(operation) failed: domain=\(error.domain) code=\(error.code) description=\(error.localizedDescription) full=\(error)")
}

func logStartupDiagnostics() {
    log("[DEBUG-task03] bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "nil")")
    log("[DEBUG-task03] bundlePath=\(Bundle.main.bundlePath)")
    log("[DEBUG-task03] executablePath=\(Bundle.main.executablePath ?? "nil") argv0=\(CommandLine.arguments[0])")
    var code: SecCode?
    let selfStatus = SecCodeCopySelf([], &code)
    log("[DEBUG-task03] SecCodeCopySelf status=\(selfStatus)")
    guard let code else { return }
    var staticCode: SecStaticCode?
    let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
    log("[DEBUG-task03] SecCodeCopyStaticCode status=\(staticStatus)")
    guard let staticCode else { return }
    var information: CFDictionary?
    let infoStatus = SecCodeCopySigningInformation(staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &information)
    log("[DEBUG-task03] SecCodeCopySigningInformation status=\(infoStatus)")
    guard let info = information as? [String: Any] else { return }
    if let flags = info[kSecCodeInfoFlags as String] as? NSNumber {
        log("[DEBUG-task03] codeSigningFlags=\(String(format: "0x%x", flags.uint32Value)) runtime=\((flags.uint32Value & 0x10000) != 0)")
    }
    if let value = info[kSecCodeInfoDesignatedRequirement as String] {
        let requirement = value as! SecRequirement
        var text: CFString?
        let status = SecRequirementCopyString(requirement, [], &text)
        log("[DEBUG-task03] designatedRequirement status=\(status) value=\(text as String? ?? "nil")")
    }
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var app: String?
    var duration = 5.0
    var ignorePreflight = false
    var out = URL(fileURLWithPath: "recordings", isDirectory: true)

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--ignore-preflight" {
                ignorePreflight = true
                index += 1
                continue
            }
            guard index + 1 < arguments.count else { throw SpikeError("Missing value: \(flag)") }
            let value = arguments[index + 1]
            switch flag {
            case "--app":
                guard !value.isEmpty else { throw SpikeError("Empty bundle ID") }
                app = value
            case "--duration":
                guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
                    throw SpikeError("--duration must be a positive finite number")
                }
                duration = seconds
            case "--out": out = URL(fileURLWithPath: value, isDirectory: true)
            default: throw SpikeError("Unknown argument: \(flag)")
            }
            index += 2
        }
    }
}

struct TrackMetadata: Codable {
    var firstSampleHostTimeSeconds: Double?
    var sampleRate: Double?
    var sourceChannels: UInt32?
    var channels = 1
    var frames: Int64 = 0
}

// Audio callbacks arrive on framework-owned threads; all mutable state is locked.
final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private var metadata = TrackMetadata()
    private var failure: String?
    private var closed = false

    init(url: URL) { self.url = url }

    func append(_ buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, failure == nil, buffer.frameLength > 0 else { return }
        do {
            guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
                let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
                let converter = AVAudioConverter(from: buffer.format, to: monoFormat) else {
                throw SpikeError("Cannot create mono converter")
            }
            try converter.convert(to: mono, from: buffer)
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: monoFormat.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                metadata.firstSampleHostTimeSeconds = hostSeconds
                metadata.sampleRate = buffer.format.sampleRate
                metadata.sourceChannels = buffer.format.channelCount
            }
            guard file?.processingFormat.sampleRate == buffer.format.sampleRate else {
                throw SpikeError("Input sample rate changed during capture")
            }
            try file?.write(from: mono)
            metadata.frames += Int64(mono.frameLength)
        } catch {
            failure = String(describing: error)
            log("Audio write failed (\(url.lastPathComponent)): \(error)")
        }
    }

    func fail(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        failure = message
    }

    func close() -> (TrackMetadata, String?) {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        file = nil // AVAudioFile closes/finalizes the AAC container on release.
        return (metadata, failure)
    }
}

final class RemoteOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let sink: AudioSink
    init(sink: AudioSink) { self.sink = sink }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        sink.fail("ScreenCaptureKit stopped: \(error)")
        log("ScreenCaptureKit stopped: \(error)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sample.isValid, CMSampleBufferDataIsReady(sample),
            let description = sample.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList)
        guard status == noErr else {
            sink.fail("Cannot copy ScreenCaptureKit PCM: \(status)")
            return
        }
        guard let clock = stream.synchronizationClock else {
            sink.fail("ScreenCaptureKit synchronization clock unavailable")
            return
        }
        // Express both capture paths in mach host seconds rather than callback arrival time.
        let time = CMSyncConvertTime(sample.presentationTimeStamp,
            from: clock, to: CMClockGetHostTimeClock())
        guard time.isNumeric else { sink.fail("Invalid audio host timestamp"); return }
        sink.append(buffer, hostSeconds: time.seconds)
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

func inputDeviceName() -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
        0, nil, &size, &device) == noErr else { return "Unknown" }
    address.mSelector = kAudioObjectPropertyName
    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return "Unknown" }
    return name?.takeRetainedValue() as String? ?? "Unknown"
}

struct Metadata: Codable {
    let targetApp: String
    let inputDeviceName: String
    let requestedDurationSeconds: Double
    let recordingDurationSeconds: Double
    let clock: String
    let videoOutputRegistered: Bool
    let remote: TrackMetadata
    let `self`: TrackMetadata
    let errors: [String]
}

@main struct Spike {
    @MainActor static func main() async {
        log("InterviewRecorderSpike PID: \(ProcessInfo.processInfo.processIdentifier)")
        logStartupDiagnostics()
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            try await record(options)
        } catch {
            logDiagnosticError("record", error)
            log("ERROR: \(error)")
            exit(1)
        }
    }

    @MainActor static func record(_ options: Options) async throws {
        let stop = StopFlag()
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { @Sendable in stop.stop() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        let preflight = CGPreflightScreenCaptureAccess()
        log("[DEBUG-task03] CGPreflightScreenCaptureAccess=\(preflight) ignorePreflight=\(options.ignorePreflight)")
        if !preflight && !options.ignorePreflight {
            log("Missing screen recording permission. Allow InterviewRecorderSpike in System Settings > Privacy & Security > Screen Recording, then relaunch.")
            _ = CGRequestScreenCaptureAccess()
            throw SpikeError("Screen recording permission unavailable")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            log("[DEBUG-task03] SCShareableContent succeeded: displays=\(content.displays.count) applications=\(content.applications.count)")
        } catch {
            logDiagnosticError("SCShareableContent", error)
            throw error
        }
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphone == .notDetermined {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw SpikeError("Missing microphone permission. Allow InterviewRecorderSpike in System Settings > Privacy & Security > Microphone.")
            }
        } else if microphone != .authorized {
            throw SpikeError("Missing microphone permission. Allow InterviewRecorderSpike in System Settings > Privacy & Security > Microphone.")
        }
        guard let display = content.displays.first else { throw SpikeError("No display available") }
        let filter: SCContentFilter
        if let appID = options.app {
            let apps = content.applications.filter { $0.bundleIdentifier == appID }
            guard !apps.isEmpty else { throw SpikeError("Target application is not running: \(appID)") }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
        for name in ["audio-remote.m4a", "audio-self.m4a", "meta.json"] {
            guard !FileManager.default.fileExists(atPath: options.out.appendingPathComponent(name).path) else {
                throw SpikeError("Refusing to overwrite existing output: \(name)")
            }
        }
        let remote = AudioSink(url: options.out.appendingPathComponent("audio-remote.m4a"))
        let local = AudioSink(url: options.out.appendingPathComponent("audio-self.m4a"))
        let output = RemoteOutput(sink: remote)
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "spike.remote"))
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpikeError("No usable microphone input") }
        let deviceName = inputDeviceName()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, time in
            guard time.isHostTimeValid else { local.fail("Microphone host timestamp unavailable"); return }
            local.append(buffer, hostSeconds: AVAudioTime.seconds(forHostTime: time.hostTime))
        }
        var errors: [String] = []
        var streamStarted = false
        let started = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        do {
            try engine.start()
            do {
                try await stream.startCapture()
                log("[DEBUG-task03] SCStream.startCapture succeeded")
            } catch {
                logDiagnosticError("SCStream.startCapture", error)
                throw error
            }
            streamStarted = true
            log("Recording \(options.app ?? "all system audio") + \(deviceName); audio output only, no video output registered")
            while !stop.value && AVAudioTime.seconds(forHostTime: mach_absolute_time()) - started < options.duration {
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch { errors.append(String(describing: error)) }
        engine.stop()
        input.removeTap(onBus: 0)
        if streamStarted {
            do { try await stream.stopCapture() } catch { errors.append(String(describing: error)) }
        }
        let (remoteMeta, remoteError) = remote.close()
        let (localMeta, localError) = local.close()
        errors += [remoteError, localError].compactMap { $0 }
        if remoteMeta.frames == 0 { errors.append("No remote audio samples received") }
        if localMeta.frames == 0 { errors.append("No microphone audio samples received") }
        let metadata = Metadata(targetApp: options.app ?? "all-system-audio", inputDeviceName: deviceName,
            requestedDurationSeconds: options.duration,
            recordingDurationSeconds: AVAudioTime.seconds(forHostTime: mach_absolute_time()) - started,
            clock: "mach host time in seconds", videoOutputRegistered: false,
            remote: remoteMeta, self: localMeta, errors: errors)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: options.out.appendingPathComponent("meta.json"), options: .atomic)
        if !errors.isEmpty { throw SpikeError(errors.joined(separator: "; ")) }
        log("Finished: \(options.out.path)")
    }
}
