import Foundation
import Observation

// MARK: - The engine port (WhisperKit adapter lives in RecorderWhisper; a SpeechAnalyzer engine would be a sibling target)

/// One session's worth of work. Core has already decided which tracks to run (silent and missing tracks are skipped
/// and their status recorded by Core), so every present entry must be transcribed.
public struct TranscribeRequest: Sendable {
    /// Final .m4a per track to transcribe. Sparse: an absent track is not run.
    public var audio: PerTrack<URL>
    public var language: String         // "ja"; explicit, never auto-detected
    public init(audio: PerTrack<URL>, language: String) { self.audio = audio; self.language = language }
}

public enum TranscriberError: Error, Sendable, Equatable {
    case modelNotInstalled
    case cancelled
    case engine(String)
}

/// Session-level port. Model load, track order, sequential vs parallel, and unload are engine policy and live in the
/// adapter: WhisperKit loads once per call, runs remote then self one at a time, and unloads before returning (also on
/// throw and cancel). Core never sees an engine type and never decides engine resource use.
public protocol Transcriber: Sendable {
    /// Provenance written into segments.json. Pure; no model load.
    func identity(language: String) -> TranscriberIdentity
    /// Returns the engine's segments for every track in `request.audio`, each in that track file's own time
    /// (seconds from the file's first sample). A present track with no speech returns `[]`, never nil.
    /// Honors Task cancellation (throws `.cancelled`); nothing is returned for a partial session.
    /// `progress(track, fraction)`: per-track 0...1, may be sparse, the adapter reports (t, 1) when a track finishes.
    /// Core turns it into one monotone session fraction (`TranscriptionProgress`). Never touches the network.
    func transcribe(_ request: TranscribeRequest,
                    progress: @escaping @Sendable (Track, Double) -> Void) async throws -> PerTrack<[EngineSegmentDTO]>
}

/// Model install is explicit and user-initiated (1.6 GB, the only network use in the app). Download + prewarm.
public protocol ModelProvider: Sendable {
    func status() async -> ModelStatus
    func install(progress: @escaping @Sendable (ModelStatus) -> Void) async throws
}

// MARK: - Progress (pure)

/// Combines the adapter's per-track fractions into one session fraction for the menu bar.
/// Weighted by track duration (Core knows them from meta.json), independent of the order the adapter runs tracks in,
/// and monotone: a fraction that goes backwards or is NaN is ignored. Tracks not in `durations` are ignored.
struct TranscriptionProgress: Sendable, Equatable {
    private let durations: PerTrack<Double>
    private var done = PerTrack<Double>()

    /// `durations`: the tracks being transcribed and their audio duration in seconds.
    init(durations: PerTrack<Double>) { self.durations = durations }

    /// 0...1 over the whole session.
    var fraction: Double {
        let present = durations.present
        guard !present.isEmpty else { return 0 }
        let total = present.reduce(0) { $0 + max($1.1, 0) }
        // All durations zero (or negative): weigh tracks equally rather than divide by zero.
        let weight: (Double) -> Double = total > 0 ? { max($0, 0) / total } : { _ in 1 / Double(present.count) }
        return present.reduce(0) { sum, entry in sum + weight(entry.1) * (done[entry.0] ?? 0) }
    }

    /// Records one adapter callback and returns the new session fraction.
    @discardableResult
    mutating func update(_ track: Track, fraction: Double) -> Double {
        guard durations[track] != nil, fraction.isFinite else { return self.fraction }
        let clamped = min(max(fraction, 0), 1)
        done[track] = max(done[track] ?? 0, clamped)
        return self.fraction
    }
}

// MARK: - Jobs

public enum TranscriptionJobState: Sendable, Equatable {
    case queued
    case waiting(WaitReason)           // cannot run now; resumes by itself when the reason clears
    case running(fraction: Double)
    case failed(String)                // user can retry; never auto-retried
    case done

    public enum WaitReason: Sendable, Equatable { case recordingInProgress, modelNotReady }
}

public struct TranscriptionJob: Sendable, Equatable, Identifiable {
    public var ref: SessionRef
    public var id: UUID { ref.id }
    public var state: TranscriptionJobState
}

/// Pure scheduling policy: which job runs next, given the world. One job (= one session) at a time (see design.md:
/// memory, ANE contention). Cancelling cancels the whole session call; nothing partial is ever written.
enum TranscriptionSchedule {
    enum Decision: Equatable { case run(UUID), idle, wait(TranscriptionJobState.WaitReason), cancelRunning }
    /// Rules: recording active => cancelRunning (if one runs) else wait(.recordingInProgress);
    /// model not ready => wait(.modelNotReady); else first `.queued`/`.waiting` job in FIFO order => run.
    static func next(jobs: [TranscriptionJob], recordingActive: Bool, modelReady: Bool) -> Decision { fatalError("not implemented") }
}

/// Owns model status, the job list and the whole session -> transcript.md pipeline.
/// UI surface: `model`, `jobs`, `enqueue`, `cancel`, `installModel`, `setRecordingActive`. Everything else is hidden.
@MainActor @Observable
public final class TranscriptionService {
    private let store: SessionStore
    private let transcriber: any Transcriber
    private let models: any ModelProvider
    private let language: @MainActor () -> String
    public private(set) var model: ModelStatus = .notInstalled
    public private(set) var jobs: [TranscriptionJob] = []

    public init(store: SessionStore, transcriber: any Transcriber, models: any ModelProvider, language: @escaping @MainActor () -> String) {
        self.store = store; self.transcriber = transcriber; self.models = models; self.language = language
    }

    /// Idempotent: enqueueing a session that is already queued/running is a no-op; one that is `.transcribed` re-transcribes
    /// (that is the "re-transcribe" button) and replaces segments.json/transcript.md only on success.
    /// Synchronous: when it returns, `jobs` already holds the ref as `.queued` (or `.waiting`), so a caller that wants to
    /// wait (the DEBUG headless runner) observes `jobs` until that ref is `.done` or `.failed`.
    public func enqueue(_ ref: SessionRef) {}
    public func cancel(_ ref: SessionRef) { fatalError("not implemented") }
    public func installModel() async { fatalError("not implemented") }
    /// Called by the composition root from RecordingController's phase hook.
    public func setRecordingActive(_ active: Bool) {}

    // run(job) pseudocode:
    //   meta = store.meta(ref); offsets = SessionTimeline.offsets(meta.tracks)
    //   for track in Track.allCases:                          // status policy stays in Core; order does not matter here
    //       audio = meta.tracks[track]?.audio; guard exists else status[track] = .skippedNoAudio; continue
    //       if audio.isEffectivelySilent { status[track] = .skippedSilent; continue }
    //       request.audio[track] = ref.folder.audio(track); durations[track] = audio.durationSeconds
    //   self.progress = TranscriptionProgress(durations: durations)    // a @MainActor stored property of the service, not a captured var
    //   raw = request.audio.present.isEmpty ? PerTrack() :
    //         try await transcriber.transcribe(request, progress: { t, f in
    //             Task { @MainActor [weak self] in self?.progressChanged(ref, t, f) } })   // the closure is @Sendable: it only hops
    //   progressChanged(ref, t, f): job.state = .running(fraction: self.progress.update(t, fraction: f))
    //   for (track, _) in request.audio.present:
    //       engine[track] = EngineOutput.normalize(raw[track] ?? [], audioDuration: durations[track]!); status[track] = .transcribed
    //   file = SegmentsFile(createdAt, transcriber.identity(language), status, TimelineBuilder.build(engine, offsets))
    //   try store.saveTranscription(ref, file)      // segments.json then transcript.md (previous -> transcript.prev.md)
    //   on cancel: job -> .queued (audio untouched, nothing partial on disk). on error: job -> .failed(msg).
    //   The adapter has already unloaded the model when transcribe returns or throws; the service never manages model memory.
}
