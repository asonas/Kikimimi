import Foundation

// Ports implemented by RecorderAudio (hardware) and by fakes in tests. Core never imports a hardware framework.

public struct InputDeviceInfo: Sendable, Equatable, Hashable, Codable {
    public var uid: String
    public var name: String
    public var inputChannels: Int
    public var isSystemDefault: Bool
    public init(uid: String, name: String, inputChannels: Int, isSystemDefault: Bool) {
        self.uid = uid; self.name = name; self.inputChannels = inputChannels; self.isSystemDefault = isSystemDefault
    }
}

public protocol InputDeviceCatalog: Sendable {
    func inputDevices() throws -> [InputDeviceInfo]
}

/// Persisted mic choice (Settings). UID is the identity; name is only for display when the device is absent.
public struct MicPreference: Sendable, Equatable, Codable {
    public var deviceUID: String
    public var deviceName: String
    /// 1-based channel to extract without downmix (Rubix44 INPUT 1 = 1). nil = downmix all channels.
    public var channel: Int?
    public init(deviceUID: String, deviceName: String, channel: Int?) {
        self.deviceUID = deviceUID; self.deviceName = deviceName; self.channel = channel
    }
}

public enum MicResolution: Sendable, Equatable {
    case use(device: InputDeviceInfo, channel: Int?)
    case notChosen                         // no preference yet: Start is blocked, onboarding asks
    case deviceMissing(MicPreference)      // blocked; NEVER falls back to the system default
    case channelOutOfRange(device: InputDeviceInfo, requested: Int)

    /// Pure. Match by UID only (names are not unique and change with firmware/localization).
    public static func resolve(_ preference: MicPreference?, available: [InputDeviceInfo]) -> MicResolution {
        guard let preference else { return .notChosen }
        guard let device = available.first(where: { $0.uid == preference.deviceUID }) else {
            return .deviceMissing(preference)
        }
        if let channel = preference.channel, channel < 1 || channel > device.inputChannels {
            return .channelOutOfRange(device: device, requested: channel)
        }
        return .use(device: device, channel: preference.channel)
    }
}

/// Everything the backend needs to run both tracks. Built by the controller after readiness + resolution succeeded.
public struct CapturePlan: Sendable {
    public var folder: SessionFolder
    public var mic: (device: InputDeviceInfo, channel: Int?)
    public var remote: RemoteSource
    /// Write-ahead hook. The backend MUST `await` this before appending the first spool chunk of a track.
    /// The controller implements it as `store.update { meta.tracks[t].firstSampleHostSeconds = host }`.
    public var willWriteFirstSample: @Sendable (Track, _ hostSeconds: Double) async -> Void
    public init(folder: SessionFolder, mic: (device: InputDeviceInfo, channel: Int?), remote: RemoteSource,
                willWriteFirstSample: @escaping @Sendable (Track, Double) async -> Void) {
        self.folder = folder; self.mic = mic; self.remote = remote; self.willWriteFirstSample = willWriteFirstSample
    }
}

public enum CaptureEvent: Sendable, Equatable {
    /// ~1 Hz peak per track, in dBFS (-120 for digital silence). Drives the meter and the silence warning.
    case level(Track, peakDBFS: Float)
    /// `DigitalSilenceDetector` changed state for this track (only `self` is watched). Computed on source samples,
    /// before gap padding. The controller feeds it to `SilenceMonitor`, the single owner of the resulting `TrackHealth`.
    case digitalSilence(Track, active: Bool)
    /// One track died; the other continues. The backend has already closed that track's spool cleanly.
    case trackFailed(Track, TrackFailure)
}

public protocol RunningCapture: Sendable {
    var events: AsyncStream<CaptureEvent> { get }
    /// Stops both sources, drains buffered chunks into the spools, closes the spool files. Never throws:
    /// per-track problems are reported through `events` before this returns. Returns what each TrackClock did.
    func stop() async -> PerTrack<ClockDiagnostics>
}

public protocol CaptureBackend: Sendable {
    /// Starts mic + remote. Throws before any spool exists if either source cannot start.
    func start(_ plan: CapturePlan) async throws -> any RunningCapture
    /// Which apps can be offered as the remote source right now (running apps; known meeting apps first).
    func runningRemoteCandidates() async throws -> [RemoteSource]
}

/// Idempotent. Turns whatever is in the folder (spool files, maybe a partial/complete m4a) into final m4a files and
/// returns facts read from the files. Safe to call twice, after a crash at any point, or on a folder that is already done.
public protocol AudioFinalizer: Sendable {
    func finalize(_ folder: SessionFolder, clockTolerance: Double) async throws -> FinalizedAudio
}

public struct FinalizedAudio: Sendable, Equatable {
    public var tracks: PerTrack<TrackAudio>
    public init(tracks: PerTrack<TrackAudio>) { self.tracks = tracks }
}
