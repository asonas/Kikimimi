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
///       if clock == nil { await plan.willWriteFirstSample(track, chunk.hostSeconds); spool = SpoolWriter(...); clock = TrackClock(rate, first)
///                         digital = DigitalSilenceDetector.forTrack(track, sampleRate: rate) }     // nil for remote
///       // BEFORE placement: the detector sees only what the device delivered, never TrackClock's padded zeros.
///       if let active = digital?.ingest(chunk.samples) { emit(.digitalSilence(track, active: active)) }
///       let p = clock.placement(chunkHostSeconds:, frameCount:) ; apply (write zeros / drop head / append) ; clock.commit(p, ...)
///       peak = max(peak, chunk.peak) ; emit .level(track, peak) once per second of audio, then reset peak
///   }   // thrown error => spool.close(); emit .trackFailed(track, mapped failure)
actor TrackRecorder {
    init(track: Track, source: any AudioSource, folder: SessionFolder, willWriteFirstSample: @escaping @Sendable (Track, Double) async -> Void,
         emit: @escaping @Sendable (CaptureEvent) -> Void) {}
    func run() async { fatalError("not implemented") }
    func stop() async -> ClockDiagnostics? { fatalError("not implemented") }
}

/// CAF, LPCM int16 little-endian, mono, at the source rate. AVAudioFile(forWriting:settings:) as in the kill -9 probe.
/// Verified on macOS 27.2: a CAF LPCM file killed with SIGKILL reopens with all but the last ~70 ms (see design.md).
struct SpoolWriter: ~Copyable {
    init(url: URL, sampleRate: Double) throws {}
    mutating func append(_ samples: [Float]) throws { fatalError("not implemented") }   // float -> int16 with clamp
    mutating func appendSilence(frames: Int) throws { fatalError("not implemented") }   // in <= 1 s blocks
    consuming func close() { fatalError("not implemented") }
}

/// spool.caf -> (AVAudioConverter to 48 kHz if the spool is above 48 kHz) -> .m4a.part (AAC 64 kbps mono) -> verify -> rename.
/// Peak scan happens during the same read pass. Verify compares the m4a's frames with the spool's frames converted to the
/// output rate (spoolFrames * outRate / spoolRate), tolerance 2048 frames (AAC priming). meta's `audio.sampleRate`/`frames`
/// are the m4a's.
struct AACFinalizer: AudioFinalizer {
    func finalize(_ folder: SessionFolder, clockTolerance: Double) async throws -> FinalizedAudio { fatalError("not implemented") }

    /// The AAC encoder fails at 96 kHz and 192 kHz and succeeds at 44.1 kHz and 48 kHz on macOS 27.2
    /// (docs/design/phase1/evidence-a/aac-sample-rates.swift). A Rubix44 can run at 96 kHz, so this is reachable.
    static let maxAACSampleRate = 48_000.0
    static func outputSampleRate(forSpoolRate rate: Double) -> Double { min(rate, maxAACSampleRate) }
}

/// Phase 0 `inputDevices()` behind the port: AudioObject enumeration with input stream config, name, UID, default flag.
struct CoreAudioInputDevices: InputDeviceCatalog {
    func inputDevices() throws -> [InputDeviceInfo] { fatalError("not implemented") }
}

/// CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess / AVCaptureDevice mic status / SCShareableContent probe.
struct SystemPermissionProbe: PermissionProbe {
    func screenPreflight() -> Bool { fatalError("not implemented") }
    func screenProbe() async -> ScreenCaptureAccess.Probe { fatalError("not implemented") }
    func requestScreen() { fatalError("not implemented") }
    func micStatus() -> MicAccess { fatalError("not implemented") }
    func requestMic() async -> Bool { fatalError("not implemented") }
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
