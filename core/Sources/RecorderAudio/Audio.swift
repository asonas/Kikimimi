import AVFoundation
import CoreAudio
import Foundation
import RecorderCore
import ScreenCaptureKit

// Everything in this file is internal except the three composition-root entry points at the bottom.
// Hardware-free logic here (spool format, AAC encode, channel extraction) is tested with synthetic PCM, like the spike's tests.

/// One mono chunk of PCM from any source, already channel-selected. Host time is mach host seconds of its first sample
/// (SCStream: CMSyncConvertTime(pts, stream.synchronizationClock -> hostTimeClock); mic: AVAudioTime.hostTime).
struct AudioChunk: Sendable {
    var hostSeconds: Double
    var sampleRate: Double
    var samples: [Float]
}

/// A source of timestamped mono chunks. Mic and remote are the same shape, so one TrackRecorder serves both
/// and the Phase 2 Core Audio Tap backend is "another AudioSource".
protocol AudioSource: Sendable {
    /// Starts capture and returns the chunk stream. The stream finishes on `stop()`; it throws if the source dies
    /// (device lost, SCStream stopped, sample rate changed). Throws here if the source cannot start at all.
    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error>
    func stop() async
}

/// SCStream audio-only, per app (SCContentFilter(display:including:[apps])) or all-system minus this process.
/// Config proven in Phase 0: capturesAudio, excludesCurrentProcessAudio, 48 kHz, 1 channel, 2x2 @ 1 fps, only `.audio` output.
final class RemoteAppSource: AudioSource {
    init(_ source: RemoteSource) {}
    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> { fatalError("not implemented") }
    func stop() async { fatalError("not implemented") }
}

/// AVAudioEngine input with kAudioOutputUnitProperty_CurrentDevice set from the device UID; format from inputFormat(forBus: 0);
/// extracts one channel without downmix (Phase 0 `extractChannel`). Observes AVAudioEngineConfigurationChange:
/// a change in device/sample rate finishes the stream with an error => track failure (.deviceLost / .formatChanged), no auto-restart in Phase 1.
final class MicSource: AudioSource {
    init(device: InputDeviceInfo, channel: Int?) {}
    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> { fatalError("not implemented") }
    func stop() async { fatalError("not implemented") }
}

/// Consumes one source for one track: write-ahead hook on the first chunk, digital-silence check, TrackClock placement,
/// spool append, level events.
/// Pseudocode:
///   for try await chunk in stream {
///       if clock == nil { try await plan.willWriteFirstSample(track, chunk.hostSeconds); spool = SpoolWriter(...); clock = TrackClock(rate, first)
///                         digital = DigitalSilenceDetector.forTrack(track, sampleRate: rate) }     // nil for remote
///       // BEFORE placement: the detector sees only what the device delivered, never TrackClock's padded zeros.
///       if let active = digital?.ingest(chunk.samples) { emit(.digitalSilence(track, active: active)) }
///       let p = clock.placement(chunkHostSeconds:, frameCount:) ; apply (write zeros / drop head / append) ; clock.commit(p, ...)
///       peak = max(peak, chunk.peak) ; emit .level(track, peak) once per second of audio, then reset peak
///   }   // thrown error => spool.close(); emit .trackFailed(track, mapped failure)
actor TrackRecorder {
    private let track: Track
    private let source: any AudioSource
    private let folder: SessionFolder
    private let willWriteFirstSample: @Sendable (Track, Double) async throws -> Void
    private let emit: @Sendable (CaptureEvent) -> Void
    private var task: Task<ClockDiagnostics?, Never>?
    private var stopped = false

    init(track: Track, source: any AudioSource, folder: SessionFolder, willWriteFirstSample: @escaping @Sendable (Track, Double) async throws -> Void,
         emit: @escaping @Sendable (CaptureEvent) -> Void) {
        self.track = track; self.source = source; self.folder = folder
        self.willWriteFirstSample = willWriteFirstSample; self.emit = emit
    }

    func run() async {
        if let task { _ = await task.value; return }
        guard !stopped else { return }
        let work = Task {
            let diagnostics = await consume()
            await source.stop()
            return diagnostics
        }
        task = work
        _ = await work.value
    }

    func stop() async -> ClockDiagnostics? {
        stopped = true
        await source.stop()
        return await task?.value
    }

    private func consume() async -> ClockDiagnostics? {
        var spool: SpoolWriter? = nil
        var clock: TrackClock?
        var digital: DigitalSilenceDetector?
        var failureCode = TrackFailure.Code.streamStopped
        var failure: TrackFailure?
        var levelFrames = 0
        var peak: Float = 0
        do {
            let stream = try await source.start()
            for try await chunk in stream {
                guard !chunk.samples.isEmpty else { continue }
                failureCode = .formatChanged
                guard chunk.sampleRate.isFinite, chunk.sampleRate >= 1,
                      clock == nil || clock?.sampleRate == chunk.sampleRate else { throw CocoaError(.fileReadCorruptFile) }
                failureCode = .streamStopped
                guard chunk.hostSeconds.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                if clock == nil {
                    failureCode = .writeFailed
                    try await willWriteFirstSample(track, chunk.hostSeconds)
                    spool = try SpoolWriter(url: folder.spool(track), sampleRate: chunk.sampleRate)
                    clock = TrackClock(sampleRate: chunk.sampleRate, firstHostSeconds: chunk.hostSeconds)
                    digital = DigitalSilenceDetector.forTrack(track, sampleRate: chunk.sampleRate)
                }
                if let active = digital?.ingest(chunk.samples) { emit(.digitalSilence(track, active: active)) }
                let placement = clock!.placement(chunkHostSeconds: chunk.hostSeconds, frameCount: chunk.samples.count)
                failureCode = .writeFailed
                switch placement {
                case .append: try spool?.append(chunk.samples)
                case .padSilence(let frames):
                    try spool?.appendSilence(frames: frames)
                    try spool?.append(chunk.samples)
                case .dropLeading(let frames): try spool?.append(Array(chunk.samples.dropFirst(frames)))
                }
                clock!.commit(placement, chunkHostSeconds: chunk.hostSeconds, frameCount: chunk.samples.count)
                for sample in chunk.samples {
                    if sample.isFinite { peak = max(peak, abs(sample)) }
                    levelFrames += 1
                    if Double(levelFrames) >= chunk.sampleRate {
                        emit(.level(track, peakDBFS: peak > 0 ? 20 * log10(peak) : -120))
                        levelFrames = 0; peak = 0
                    }
                }
                failureCode = .streamStopped
            }
        } catch {
            failure = TrackFailure(code: failureCode, message: String(describing: error),
                                   atSeconds: clock.map { Double($0.framesPlaced) / $0.sampleRate })
        }
        if let writer = consume spool { writer.close() }
        if let failure { emit(.trackFailed(track, failure)) }
        return clock?.diagnostics
    }
}

/// CAF, LPCM int16 little-endian, mono, at the source rate. AVAudioFile(forWriting:settings:) as in the kill -9 probe.
/// Verified on macOS 27.2: a CAF LPCM file killed with SIGKILL reopens with all but the last ~70 ms (see design.md).
struct SpoolWriter: ~Copyable {
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private let syncFD: Int32
    private var unsyncedFrames = 0

    init(url: URL, sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate >= 1,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
        else { throw CocoaError(.fileWriteInvalidFileName) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        self.format = format
        self.file = file
        self.syncFD = fd
    }

    mutating func append(_ samples: [Float]) throws {
        let block = Int(format.sampleRate)
        for start in stride(from: 0, to: samples.count, by: block) {
            let count = min(block, samples.count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            let output = buffer.int16ChannelData![0]
            for i in 0..<count {
                let sample = samples[start + i]
                let clamped = sample.isNaN ? 0 : min(1, max(-1, sample))
                output[i] = Int16(clamping: Int((Double(clamped) * 32768).rounded()))
            }
            try file!.write(from: buffer)
            unsyncedFrames += count
            if Double(unsyncedFrames) >= format.sampleRate * 5 {
                guard fsync(syncFD) == 0 else { throw POSIXError(.EIO) }
                unsyncedFrames = 0
            }
        }
    }

    mutating func appendSilence(frames: Int) throws {
        guard frames >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, Int(format.sampleRate))
            try append([Float](repeating: 0, count: count))
            remaining -= count
        }
    }

    consuming func close() { file = nil }
    deinit { _ = fsync(syncFD); Darwin.close(syncFD) }
}

/// spool.caf -> (AVAudioConverter to 48 kHz if the spool is above 48 kHz) -> .m4a.part (AAC 64 kbps mono) -> verify -> rename.
/// Peak scan happens during the same read pass. Verify compares the m4a's frames with the spool's frames converted to the
/// output rate (spoolFrames * outRate / spoolRate), tolerance 2048 frames (AAC priming). meta's `audio.sampleRate`/`frames`
/// are the m4a's.
struct AACFinalizer: AudioFinalizer {
    func finalize(_ folder: SessionFolder, clockTolerance: Double) async throws -> FinalizedAudio {
        let manager = FileManager.default
        var tracks = PerTrack<TrackAudio>()
        for track in Track.allCases {
            let spool = folder.spool(track), final = folder.audio(track), part = folder.audioPart(track)
            if manager.fileExists(atPath: part.path) { try manager.removeItem(at: part) }
            if manager.fileExists(atPath: final.path) {
                tracks[track] = try facts(final)
                if manager.fileExists(atPath: spool.path) { try manager.removeItem(at: spool) }
            } else if manager.fileExists(atPath: spool.path) {
                try repairSpoolTail(spool)
                let input = try AVAudioFile(forReading: spool)
                let rate = Self.outputSampleRate(forSpoolRate: input.processingFormat.sampleRate)
                let expected = Double(input.length) * rate / input.processingFormat.sampleRate
                try encode(input, to: part, rate: rate)
                let audio = try verify(url: part, expectedFrames: expected)
                try manager.moveItem(at: part, to: final)
                try manager.removeItem(at: spool)
                var value = audio; value.file = final.lastPathComponent
                tracks[track] = value
            }
        }
        return FinalizedAudio(tracks: tracks)
    }

    func verify(url: URL, expectedFrames: Double) throws -> TrackAudio {
        let audio = try facts(url)
        guard expectedFrames.isFinite, abs(Double(audio.frames) - expectedFrames) <= 2048 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return audio
    }

    // CAF's data chunk may have an unfinished (-1) size or a partial int16 at its tail.
    private func repairSpoolTail(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard try handle.read(upToCount: 4) == Data("caff".utf8) else { throw CocoaError(.fileReadCorruptFile) }
        var offset: UInt64 = 8
        while offset + 12 <= size {
            try handle.seek(toOffset: offset)
            let header = try handle.read(upToCount: 12) ?? Data()
            guard header.count == 12 else { throw CocoaError(.fileReadCorruptFile) }
            if header.prefix(4) == Data("data".utf8) {
                let start = offset + 16
                guard size >= start else { throw CocoaError(.fileReadCorruptFile) }
                try handle.truncate(atOffset: start + (size - start) / 2 * 2)
                try handle.seek(toOffset: offset + 4)
                try handle.write(contentsOf: Data(repeating: 0xff, count: 8))
                return
            }
            let length = header.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard length <= size - offset - 12 else { throw CocoaError(.fileReadCorruptFile) }
            offset += 12 + length
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func encode(_ input: AVAudioFile, to url: URL, rate: Double) throws {
        let output = try AVAudioFile(forWriting: url, settings: [
            AVAudioFileTypeKey: kAudioFileM4AType, AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        guard let converter = AVAudioConverter(from: input.processingFormat, to: output.processingFormat),
              let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192),
              let destination = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 8192)
        else { throw CocoaError(.fileReadCorruptFile) }
        var readError: (any Error)?
        while true {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: destination, error: &error) { requested, status in
                guard input.framePosition < input.length else { status.pointee = .endOfStream; return nil }
                do {
                    let count = min(Int64(min(requested, source.frameCapacity)), input.length - input.framePosition)
                    try input.read(into: source, frameCount: AVAudioFrameCount(count))
                    status.pointee = source.frameLength > 0 ? .haveData : .endOfStream
                    return source.frameLength > 0 ? source : nil
                } catch { readError = error; status.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let error { throw error }
            if destination.frameLength > 0 { try output.write(from: destination) }
            if status == .endOfStream { break }
            if status == .error { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    private func facts(_ url: URL) throws -> TrackAudio {
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.channelCount == 1, file.length > 0,
              file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)
        else { throw CocoaError(.fileReadCorruptFile) }
        var peak: Float = 0
        var read: Int64 = 0
        while read < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - read)))
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][i])) }
            read += Int64(buffer.frameLength)
        }
        return TrackAudio(file: url.lastPathComponent, sampleRate: file.fileFormat.sampleRate,
                          frames: file.length, peakDBFS: peak > 0 ? 20 * log10(Double(peak)) : -120)
    }

    /// The AAC encoder fails at 96 kHz and 192 kHz and succeeds at 44.1 kHz and 48 kHz on macOS 27.2
    /// (docs/design/phase1/evidence-a/aac-sample-rates.swift). A Rubix44 can run at 96 kHz, so this is reachable.
    static let maxAACSampleRate = 48_000.0
    static func outputSampleRate(forSpoolRate rate: Double) -> Double { min(rate, maxAACSampleRate) }
}

/// Phase 0 `inputDevices()` behind the port: AudioObject enumeration with input stream config, name, UID, default flag.
struct CoreAudioInputDevices: InputDeviceCatalog {
    func inputDevices() throws -> [InputDeviceInfo] { [] } // Replaced by the device-catalog implementation commit.
}

/// CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess / AVCaptureDevice mic status / SCShareableContent probe.
struct SystemPermissionProbe: PermissionProbe {
    func screenPreflight() -> Bool { CGPreflightScreenCaptureAccess() }
    func screenProbe() async -> ScreenCaptureAccess.Probe {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return .succeeded
        } catch { return .failed(code: (error as NSError).code) }
    }
    func requestScreen() { _ = CGRequestScreenCaptureAccess() }
    func micStatus() -> MicAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .restricted
        }
    }
    func requestMic() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
}

/// Mic + remote, each through TrackRecorder. If one source throws on start, the other is stopped and the error propagates
/// (no spool is left behind: spools are created lazily on the first chunk).
struct TwoTrackCapture: CaptureBackend {
    func start(_ plan: CapturePlan) async throws -> any RunningCapture { fatalError("not implemented") }
    func runningRemoteCandidates() async throws -> [RemoteSource] { fatalError("not implemented") }
}

// MARK: - The only public surface of RecorderAudio (composition root uses these)

public enum LiveAudio {
    public static func backend() -> any CaptureBackend { TwoTrackCapture() }
    public static func finalizer() -> any AudioFinalizer { AACFinalizer() }
    public static func devices() -> any InputDeviceCatalog { CoreAudioInputDevices() }
    public static func permissions() -> any PermissionProbe { SystemPermissionProbe() }
}
