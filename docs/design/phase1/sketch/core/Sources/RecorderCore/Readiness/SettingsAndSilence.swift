import Foundation
import Observation

/// One Codable blob in UserDefaults under "settings.v1". Single schema, injectable suite for tests.
public struct Settings: Sendable, Equatable, Codable {
    /// nil until the user confirms a mic in onboarding. There is deliberately no "system default" mode:
    /// the built-in mic yields digital silence in clamshell mode (Phase 0 finding).
    public var mic: MicPreference?
    public var remote: RemoteSource?
    public var language = "ja"
    /// Exact folder name in argmaxinc/whisperkit-coreml. Recorded into segments.json for provenance.
    public var modelVariant = ModelSpec.defaultVariant
    /// Our own flag: CGPreflightScreenCaptureAccess cannot tell "never asked" from "denied".
    public var screenCaptureRequested = false
    /// nil = ~/Library/Application Support/InterviewRecorder/Recordings (no UI in Phase 1; plumbing only).
    public var recordingsRoot: URL?
    public init() {}
}

public enum ModelSpec {
    /// 32 encoder / 4 decoder layers, 128 mels (verified from the repo's config.json) = OpenAI large-v3-turbo.
    /// Passed to WhisperKit.download(variant:) whose glob `*<variant>/*` matches exactly this folder
    /// (the `_632MB` sibling does not match because the glob requires `turbo/`).
    public static let defaultVariant = "openai_whisper-large-v3-v20240930_turbo"
    /// Folder is complete iff these exist and our marker was written after a successful download+prewarm.
    public static let requiredEntries = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc",
                                         "TextDecoderContextPrefill.mlmodelc", "config.json", "generation_config.json"]
    public static let installMarker = ".interview-recorder-installed"
}

@MainActor @Observable
public final class SettingsStore {
    public var settings: Settings { didSet { fatalError("persist to UserDefaults JSON; no-op if unchanged") } }
    public init(defaults: UserDefaults = .standard) { fatalError("not implemented") }
}

/// Pure silence/liveness tracking. The ONLY writer of a track's non-failure `TrackHealth`: it merges the 1 Hz level events
/// and the digital-silence signal, so the controller never combines two monitors itself. Emits only on change.
/// Level rule: waitingForAudio -> live when peak > -75 dBFS; live -> silent after `silentAfter` seconds below it; silent -> live when above.
/// Precedence: digitallySilent (while the detector is active) > silent > live > waitingForAudio. When the detector clears,
/// the health falls back to what the level rule says at that moment.
struct SilenceMonitor: Sendable {
    var thresholdDBFS: Float = -75
    var silentAfter: TimeInterval = 20
    private var lastAbove: [Track: TimeInterval] = [:]
    private var digital: Set<Track> = []
    private var current: [Track: TrackHealth] = [:]
    /// `at` is any monotonic seconds value (host seconds). Returns the new health if it changed.
    mutating func ingest(_ track: Track, peakDBFS: Float, at: TimeInterval) -> TrackHealth? { fatalError("not implemented") }
    /// From `CaptureEvent.digitalSilence`. Returns the new health if it changed.
    mutating func digitalSilence(_ track: Track, active: Bool) -> TrackHealth? { fatalError("not implemented") }
}
