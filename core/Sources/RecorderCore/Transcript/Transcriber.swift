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
    static func next(jobs: [TranscriptionJob], recordingActive: Bool, modelReady: Bool) -> Decision {
        let running = jobs.contains { if case .running = $0.state { return true }; return false }
        if recordingActive { return running ? .cancelRunning : .wait(.recordingInProgress) }
        if !modelReady { return .wait(.modelNotReady) }
        if running { return .idle }
        if let first = jobs.first(where: { $0.state.isPending }) { return .run(first.id) }
        return .idle
    }
}

private extension TranscriptionJobState {
    var isPending: Bool { switch self { case .queued, .waiting: true; default: false } }
    var isRunning: Bool { if case .running = self { true } else { false } }
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
    private var recordingActive = false
    private var initialized = false
    private var statusTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var installToken: UUID?
    private var worker: Task<Void, Never>?
    private var currentID: UUID?
    private var currentToken: UUID?
    private var removeWhenCancelled = false
    private var progress: TranscriptionProgress?

    public init(store: SessionStore, transcriber: any Transcriber, models: any ModelProvider, language: @escaping @MainActor () -> String) {
        self.store = store; self.transcriber = transcriber; self.models = models; self.language = language
        statusTask = Task { [weak self, models] in
            let status = await models.status()
            guard let self else { return }
            self.model = status; self.initialized = true
            self.schedule()
        }
    }

    /// Idempotent: enqueueing a session that is already queued/running is a no-op; one that is `.transcribed` re-transcribes
    /// (that is the "re-transcribe" button) and replaces segments.json/transcript.md only on success.
    /// Synchronous: when it returns, `jobs` already holds the ref as `.queued` (or `.waiting`), so a caller that wants to
    /// wait (the DEBUG headless runner) observes `jobs` until that ref is `.done` or `.failed`.
    public func enqueue(_ ref: SessionRef) {
        if jobs.contains(where: { $0.id == ref.id && ($0.state.isPending || $0.state.isRunning) }) { return }
        jobs.removeAll { $0.id == ref.id }
        jobs.append(.init(ref: ref, state: .queued))
        schedule()
    }
    public func cancel(_ ref: SessionRef) {
        if currentID == ref.id {
            removeWhenCancelled = true
            worker?.cancel()
        } else {
            jobs.removeAll { $0.id == ref.id }
            schedule()
        }
    }
    public func installModel() async {
        await statusTask?.value
        if let installTask { await installTask.value; return }
        guard model != .ready else { return }
        let token = UUID()
        installToken = token
        model = .downloading(fraction: 0)
        let task = Task { [weak self, models] in
            let service = self
            do {
                try await models.install { [weak service] status in
                    guard let service else { return }
                    Task { @MainActor [weak service = service] in
                        guard service?.installToken == token else { return }
                        service?.model = status
                    }
                }
                let status = await models.status()
                self?.model = status
            } catch { self?.model = .failed(String(describing: error)) }
            self?.installToken = nil; self?.installTask = nil
            self?.schedule()
        }
        installTask = task
        schedule()
        await task.value
    }
    /// Called by the composition root from RecordingController's phase hook.
    public func setRecordingActive(_ active: Bool) {
        recordingActive = active
        if active { worker?.cancel() }
        schedule()
    }

    private func schedule() {
        if worker != nil {
            if recordingActive { setPending(.waiting(.recordingInProgress)) }
            return
        }
        guard initialized, installTask == nil else { setPending(.waiting(.modelNotReady)); return }
        switch TranscriptionSchedule.next(jobs: jobs, recordingActive: recordingActive, modelReady: model == .ready) {
        case .idle: break
        case .cancelRunning: worker?.cancel()
        case .wait(let reason): setPending(.waiting(reason))
        case .run(let id):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            let ref = jobs[index].ref, token = UUID()
            jobs[index].state = .running(fraction: 0)
            currentID = id; currentToken = token; removeWhenCancelled = false
            worker = Task { [weak self] in await self?.run(ref, token: token) }
        }
    }

    private func setPending(_ state: TranscriptionJobState) {
        for index in jobs.indices where jobs[index].state.isPending { jobs[index].state = state }
    }

    private func run(_ ref: SessionRef, token: UUID) async {
        do {
            try Task.checkCancellation()
            let meta = try await store.meta(of: ref)
            guard case .finished = meta.capture, !CaptureLease.isHeld(ref.folder.lock) else { throw CocoaError(.fileWriteNoPermission) }
            var audio = PerTrack<URL>(), durations = PerTrack<Double>(), statuses = PerTrack<TrackTranscriptionStatus>()
            for track in Track.allCases {
                guard let facts = meta.tracks[track]?.audio else { statuses[track] = .skippedNoAudio; continue }
                guard FileManager.default.fileExists(atPath: ref.folder.audio(track).path) else { throw CocoaError(.fileNoSuchFile) }
                if facts.isEffectivelySilent { statuses[track] = .skippedSilent; continue }
                audio[track] = ref.folder.audio(track); durations[track] = facts.durationSeconds
            }
            progress = TranscriptionProgress(durations: durations)
            let language = language()
            try Task.checkCancellation()
            let raw: PerTrack<[EngineSegmentDTO]>
            if audio.present.isEmpty { raw = .init() }
            else {
                raw = try await transcriber.transcribe(.init(audio: audio, language: language)) { [weak self] track, fraction in
                    Task { @MainActor [weak self] in self?.progressChanged(ref, token: token, track: track, fraction: fraction) }
                }
            }
            try Task.checkCancellation()
            var normalized = PerTrack<[EngineSegment]>()
            for (track, _) in audio.present {
                guard let result = raw[track] else { throw TranscriberError.engine("Missing output for \(track.rawValue)") }
                normalized[track] = EngineOutput.normalize(result, audioDuration: durations[track]!)
                statuses[track] = .transcribed
            }
            let segments = try TimelineBuilder.build(tracks: normalized, offsets: SessionTimeline.offsets(of: meta.tracks))
            let file = SegmentsFile(schemaVersion: SegmentsFile.currentSchemaVersion, createdAt: Date(),
                transcriber: transcriber.identity(language: language), tracks: statuses, segments: segments)
            try Task.checkCancellation()
            try await store.saveTranscription(ref, file)
            // Cancellation after the store's commit boundary cannot turn a completed save back into queued work.
            finish(ref, token: token, state: .done, remove: removeWhenCancelled)
        } catch {
            let cancelled = Task.isCancelled
            if cancelled { finish(ref, token: token, state: .queued, remove: removeWhenCancelled) }
            else if (error as? TranscriberError) == .modelNotInstalled {
                model = .notInstalled
                finish(ref, token: token, state: .queued)
            } else { finish(ref, token: token, state: .failed(String(describing: error))) }
        }
    }

    private func progressChanged(_ ref: SessionRef, token: UUID, track: Track, fraction: Double) {
        guard currentToken == token, worker?.isCancelled == false,
              let index = jobs.firstIndex(where: { $0.id == ref.id }), let value = progress?.update(track, fraction: fraction) else { return }
        jobs[index].state = .running(fraction: value)
    }

    private func finish(_ ref: SessionRef, token: UUID, state: TranscriptionJobState, remove: Bool = false) {
        guard currentToken == token else { return }
        if remove { jobs.removeAll { $0.id == ref.id } }
        else if let index = jobs.firstIndex(where: { $0.id == ref.id }) { jobs[index].state = state }
        worker = nil; currentID = nil; currentToken = nil; progress = nil
        schedule()
    }

}
