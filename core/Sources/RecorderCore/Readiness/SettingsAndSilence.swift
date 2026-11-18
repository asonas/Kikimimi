import Foundation
import Observation

public enum SummaryProvider: String, Sendable, Codable, CaseIterable {
    case apiKey, chatGPT
}

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
    /// nil = ~/Library/Application Support/Kikimimi/Recordings (no UI in Phase 1; plumbing only).
    public var recordingsRoot: URL?
    /// nil selects every calendar, including calendars added later.
    public var calendarIDs: Set<String>?
    public var summaryModel = "gpt-6.1-sol"
    public var summaryConsent = false
    public var summaryProvider = SummaryProvider.apiKey
    public var exportFolder: String?
    /// After a new recording is transcribed, summarize it and export the note. Turning it on is the consent to send.
    public var autoSummarizeAndExport = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case mic, remote, language, modelVariant, screenCaptureRequested, recordingsRoot, calendarIDs, summaryModel, summaryConsent, summaryProvider, exportFolder, autoSummarizeAndExport
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mic = try c.decodeIfPresent(MicPreference.self, forKey: .mic)
        remote = try c.decodeIfPresent(RemoteSource.self, forKey: .remote)
        language = try c.decode(String.self, forKey: .language)
        modelVariant = try c.decode(String.self, forKey: .modelVariant)
        screenCaptureRequested = try c.decode(Bool.self, forKey: .screenCaptureRequested)
        recordingsRoot = try c.decodeIfPresent(URL.self, forKey: .recordingsRoot)
        calendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .calendarIDs)
        summaryModel = try c.decodeIfPresent(String.self, forKey: .summaryModel) ?? "gpt-6.1-sol"
        summaryConsent = try c.decodeIfPresent(Bool.self, forKey: .summaryConsent) ?? false
        summaryProvider = try c.decodeIfPresent(SummaryProvider.self, forKey: .summaryProvider) ?? .apiKey
        exportFolder = try c.decodeIfPresent(String.self, forKey: .exportFolder)
        autoSummarizeAndExport = try c.decodeIfPresent(Bool.self, forKey: .autoSummarizeAndExport) ?? false
    }
}

public enum ModelSpec {
    /// 32 encoder / 4 decoder layers, 128 mels (verified from the repo's config.json) = OpenAI large-v3-turbo.
    /// Passed to WhisperKit.download(variant:) whose glob `*<variant>/*` matches exactly this folder
    /// (the `_632MB` sibling does not match because the glob requires `turbo/`).
    public static let defaultVariant = "openai_whisper-large-v3-v20240930_turbo"
    /// Folder is complete iff these exist and our marker was written after a successful download+prewarm.
    public static let requiredEntries = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc",
                                         "TextDecoderContextPrefill.mlmodelc", "config.json", "generation_config.json"]
    public static let installMarker = "installed.json"
    public static let tokenizerEntries = ["tokenizer.json", "tokenizer_config.json"]
}

@MainActor @Observable
public final class SettingsStore {
    public nonisolated static let key = "settings.v1"
    private let defaults: UserDefaults
    public var settings: Settings {
        didSet {
            guard settings != oldValue, let data = try? JSONEncoder().encode(settings) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }
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
    private var level: [Track: TrackHealth] = [:]
    /// `at` is any monotonic seconds value (host seconds). Returns the new health if it changed.
    mutating func ingest(_ track: Track, peakDBFS: Float, at: TimeInterval) -> TrackHealth? {
        guard at.isFinite, !peakDBFS.isNaN else { return nil }
        if peakDBFS > thresholdDBFS {
            lastAbove[track] = at
            level[track] = .live
        } else {
            if lastAbove[track] == nil { lastAbove[track] = at }
            if at - lastAbove[track]! >= silentAfter { level[track] = .silent }
        }
        return emitIfChanged(track)
    }
    /// From `CaptureEvent.digitalSilence`. Returns the new health if it changed.
    mutating func digitalSilence(_ track: Track, active: Bool) -> TrackHealth? {
        if active { digital.insert(track) } else { digital.remove(track) }
        return emitIfChanged(track)
    }

    private mutating func emitIfChanged(_ track: Track) -> TrackHealth? {
        let health: TrackHealth = digital.contains(track) ? .digitallySilent : (level[track] ?? .waitingForAudio)
        guard health != (current[track] ?? .waitingForAudio) else { return nil }
        current[track] = health
        return health
    }
}
