import Foundation

public enum SessionMetaError: Error, Sendable, Equatable {
    case newerThanSupported(found: Int, supported: Int)
}

/// meta.json. Capture facts only. Written by `SessionStore` (the single writer).
/// Transcription provenance lives in segments.json, never here.
public struct SessionMeta: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var company: String
    public var title: String?
    /// IANA identifier at capture time, so local date and folder name are re-derivable.
    public var timeZone: String
    public var startedAt: Date
    public var capture: CaptureStatus
    public var app: AppInfo
    /// Always "mach-host-seconds": `firstSampleHostSeconds` values are comparable only within one boot.
    public var clock: String
    public var tracks: PerTrack<TrackMeta>

    public init(id: UUID, company: String, title: String?, timeZone: String, startedAt: Date,
                app: AppInfo, tracks: PerTrack<TrackMeta>) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id; self.company = company; self.title = title; self.timeZone = timeZone
        self.startedAt = startedAt; self.capture = .inProgress; self.app = app
        self.clock = "mach-host-seconds"; self.tracks = tracks
    }
}

public struct AppInfo: Sendable, Equatable, Codable {
    public var version: String
    public var build: String
    public var os: String
    public init(version: String, build: String, os: String) { self.version = version; self.build = build; self.os = os }
}

/// `endedAt` and `endReason` are both present or both absent in JSON. Decoding rejects half-states.
public enum CaptureStatus: Sendable, Equatable {
    case inProgress
    case finished(endedAt: Date, reason: EndReason)
}
extension CaptureStatus {
    // Flattened into the parent object, see SessionMeta's custom keys below.
}

/// Everything known about one track. `source` is set at start (the plan); `audio` is filled by finalize.
public struct TrackMeta: Sendable, Equatable, Codable {
    public var source: TrackSource
    /// Host-clock time of the first sample ever written to the spool. Written to meta.json
    /// *before* the first spool append (write-ahead), so a crash never leaves audio without its anchor.
    public var firstSampleHostSeconds: Double?
    public var audio: TrackAudio?
    /// Only known on the live stop path (the in-memory TrackClock). nil after crash recovery. Diagnostics, not truth.
    public var diagnostics: ClockDiagnostics?
    public var failure: TrackFailure?
    public init(source: TrackSource, firstSampleHostSeconds: Double? = nil, audio: TrackAudio? = nil,
                diagnostics: ClockDiagnostics? = nil, failure: TrackFailure? = nil) {
        self.source = source; self.firstSampleHostSeconds = firstSampleHostSeconds; self.audio = audio
        self.diagnostics = diagnostics; self.failure = failure
    }
}

/// What `TrackClock` did during capture. Useful for tuning `tolerance` with real recordings.
public struct ClockDiagnostics: Sendable, Equatable, Codable {
    public var gapFillFrames: Int64
    public var gapCount: Int
    public var overlapDroppedFrames: Int64
    public var maxAbsDriftSeconds: Double
    public init(gapFillFrames: Int64, gapCount: Int, overlapDroppedFrames: Int64, maxAbsDriftSeconds: Double) {
        self.gapFillFrames = gapFillFrames; self.gapCount = gapCount
        self.overlapDroppedFrames = overlapDroppedFrames; self.maxAbsDriftSeconds = maxAbsDriftSeconds
    }
}

/// Where a track's audio comes from. Explicit `kind` discriminator in JSON.
public enum TrackSource: Sendable, Equatable {
    case mic(deviceUID: String, deviceName: String, channel: Int?, deviceChannels: Int)
    case app(bundleID: String, name: String)
    case allSystemAudio
}

/// Facts derived from the finished audio by `finalize` (never hand-edited, always recomputable from the files).
public struct TrackAudio: Sendable, Equatable, Codable {
    public var file: String            // "audio-self.m4a"
    public var sampleRate: Double      // rate of the encoded m4a: the spool's rate, or 48 kHz if the spool was above 48 kHz
    public var frames: Int64           // frames in the m4a at `sampleRate` = timeline length of this track
    public var peakDBFS: Double        // overall peak; <= -70 means the track is effectively silent
    public init(file: String, sampleRate: Double, frames: Int64, peakDBFS: Double) {
        self.file = file; self.sampleRate = sampleRate; self.frames = frames; self.peakDBFS = peakDBFS
    }
    public var durationSeconds: Double { Double(frames) / sampleRate }
    public var isEffectivelySilent: Bool { peakDBFS <= -70 }
}

// MARK: Codable (custom shapes)

extension TrackSource: Codable {
    private enum Keys: String, CodingKey { case kind, deviceUID, deviceName, channel, deviceChannels, bundleID, name }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "mic":
            self = .mic(deviceUID: try c.decode(String.self, forKey: .deviceUID),
                        deviceName: try c.decode(String.self, forKey: .deviceName),
                        channel: try c.decodeIfPresent(Int.self, forKey: .channel),
                        deviceChannels: try c.decode(Int.self, forKey: .deviceChannels))
        case "app":
            self = .app(bundleID: try c.decode(String.self, forKey: .bundleID), name: try c.decode(String.self, forKey: .name))
        case "allSystemAudio": self = .allSystemAudio
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown track source kind \(other)")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .mic(uid, name, channel, deviceChannels):
            try c.encode("mic", forKey: .kind); try c.encode(uid, forKey: .deviceUID); try c.encode(name, forKey: .deviceName)
            try c.encodeIfPresent(channel, forKey: .channel); try c.encode(deviceChannels, forKey: .deviceChannels)
        case let .app(bundleID, name):
            try c.encode("app", forKey: .kind); try c.encode(bundleID, forKey: .bundleID); try c.encode(name, forKey: .name)
        case .allSystemAudio: try c.encode("allSystemAudio", forKey: .kind)
        }
    }
}

extension SessionMeta {
    private enum Keys: String, CodingKey {
        case schemaVersion, id, company, title, timeZone, startedAt, endedAt, endReason, app, clock, tracks
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw SessionMetaError.newerThanSupported(found: schemaVersion, supported: Self.currentSchemaVersion)
        }
        id = try c.decode(UUID.self, forKey: .id)
        company = try c.decode(String.self, forKey: .company)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        timeZone = try c.decode(String.self, forKey: .timeZone)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        let endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        let reason = try c.decodeIfPresent(EndReason.self, forKey: .endReason)
        switch (endedAt, reason) {
        case (nil, nil): capture = .inProgress
        case let (e?, r?): capture = .finished(endedAt: e, reason: r)
        default: throw DecodingError.dataCorruptedError(forKey: .endedAt, in: c, debugDescription: "endedAt and endReason must be both present or both absent")
        }
        app = try c.decode(AppInfo.self, forKey: .app)
        clock = try c.decode(String.self, forKey: .clock)
        tracks = try c.decode(PerTrack<TrackMeta>.self, forKey: .tracks)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(id, forKey: .id)
        try c.encode(company, forKey: .company); try c.encodeIfPresent(title, forKey: .title)
        try c.encode(timeZone, forKey: .timeZone); try c.encode(startedAt, forKey: .startedAt)
        if case let .finished(endedAt, reason) = capture {
            try c.encode(endedAt, forKey: .endedAt); try c.encode(reason, forKey: .endReason)
        }
        try c.encode(app, forKey: .app); try c.encode(clock, forKey: .clock); try c.encode(tracks, forKey: .tracks)
    }
}
