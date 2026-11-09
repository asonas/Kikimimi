// Verified by compiling this file against WhisperKit v1.1.1 in Swift 6 language mode (`swift test` builds this target):
//   WhisperKit.init(_ config:) ; static download(variant:downloadBase:progressCallback:) -> URL with progressCallback: (Progress) -> Void;
//   kit.progress: Progress ; transcribe(audioPath:audioInputOptions:decodeOptions:callback:) ; AudioInputOptions(audioLoadingMode: .incremental);
//   DecodingOptions.language/detectLanguage/skipSpecialTokens/chunkingStrategy are settable; WhisperKitConfig(modelFolder:verbose:prewarm:load:download:);
//   unloadModels() async.
//   Compiles with a plain `import WhisperKit` (no @preconcurrency needed) because the non-Sendable WhisperKit object never
//   leaves this actor.
// Read from WhisperKit 1.1.1 source (candidate A, design time): on the `.incremental` loading path, segment times are
//   corrected to absolute file time (`updateSegmentTimings`), and no segment callback is passed, so in-track progress is coarse.
// NOT verifiable by compiling (the gated integration test must establish them): Task cancellation latency inside transcribe;
//   that segment times are file-relative across VAD windows on the incremental path; first-load Core ML specialization time.
import Foundation
import RecorderCore
import WhisperKit

public enum LiveWhisper {
    /// One object, two ports: Transcriber (run) and ModelProvider (install/status). `base` = .../InterviewRecorder/Models.
    public static func engine(base: URL, variant: String) -> WhisperKitEngine { WhisperKitEngine(base: base, variant: variant) }
}

public actor WhisperKitEngine: Transcriber, ModelProvider {
    private let base: URL
    private let variant: String

    init(base: URL, variant: String) { self.base = base; self.variant = variant }

    /// Engine policy, owned here: remote then self, one at a time with one model instance (two large-v3-turbo instances
    /// double memory and contend for the ANE/GPU, so parallel is not faster). A SpeechAnalyzer adapter may choose differently.
    static func trackOrder(_ audio: PerTrack<URL>) -> [Track] {
        [Track.remote, .me].filter { audio[$0] != nil }
    }

    // MARK: Transcriber

    public nonisolated func identity(language: String) -> TranscriberIdentity {
        TranscriberIdentity(engine: "whisperkit", engineVersion: "1.1.1", model: variant, language: language, chunking: "vad")
    }

    public func transcribe(_ request: TranscribeRequest,
                           progress: @escaping @Sendable (Track, Double) -> Void) async throws -> PerTrack<[EngineSegmentDTO]> {
        // Load per session, unload before returning on every path. `download: false`: transcription can never reach the network.
        let kit = try await load()
        do {
            let out = try await run(kit, request, progress: progress)
            await kit.unloadModels()
            return out
        } catch {
            await kit.unloadModels()
            throw (error is CancellationError) ? TranscriberError.cancelled : error
        }
    }

    private func run(_ kit: WhisperKit, _ request: TranscribeRequest,
                     progress: @escaping @Sendable (Track, Double) -> Void) async throws -> PerTrack<[EngineSegmentDTO]> {
        var options = DecodingOptions()
        options.language = request.language
        options.detectLanguage = false          // a self track that starts in silence must not be language-sniffed
        options.skipSpecialTokens = true
        options.chunkingStrategy = .vad         // skips long silences: fewer hallucinations, faster
        // Streams the file instead of holding it as one 16 kHz buffer (a 90-minute track would be ~346 MB).
        let input = AudioInputOptions(audioLoadingMode: .incremental)

        var out = PerTrack<[EngineSegmentDTO]>()
        for track in Self.trackOrder(request.audio) {
            try Task.checkCancellation()
            guard let url = request.audio[track] else { continue }
            progress(track, 0)
            // TODO progress: sample kit.progress.fractionCompleted at 2 Hz while this call runs and report progress(track, f);
            //      Core clamps it monotone. Coarse on the incremental path (no segment callback); commit 19 measures it.
            let results = try await kit.transcribe(audioPath: url.path, audioInputOptions: input, decodeOptions: options)
            try Task.checkCancellation()
            // One-line copy. All interpretation is EngineOutput.normalize in Core (pure, tested).
            out[track] = results.flatMap(\.segments).map {
                EngineSegmentDTO(start: $0.start, end: $0.end, text: $0.text,
                                 avgLogprob: $0.avgLogprob, noSpeechProb: $0.noSpeechProb, compressionRatio: $0.compressionRatio)
            }
            progress(track, 1)
        }
        return out
    }

    private func load() async throws -> WhisperKit {
        guard let folder = try await installedFolder() else { throw TranscriberError.modelNotInstalled }
        return try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false, prewarm: false, load: true, download: false))
    }

    // MARK: ModelProvider

    /// Installed iff installed.json (written by us AFTER download + prewarm succeeded) names this variant and every
    /// ModelSpec.requiredEntries path exists under its folder. We trust neither WhisperKit's folder layout nor a partial snapshot.
    public func status() async -> ModelStatus { fatalError("not implemented") }

    public func install(progress: @escaping @Sendable (ModelStatus) -> Void) async throws {
        // 1. let folder = try await WhisperKit.download(variant: variant, downloadBase: base,
        //        progressCallback: { p in progress(.downloading(fraction: p.fractionCompleted)) })
        // 2. progress(.optimizing); load with prewarm: true, download: false; unload.
        //    (pays the first-time Core ML specialization now, with a visible state, not during the first real transcription)
        // 3. validate ModelSpec.requiredEntries; write installed.json {variant, folder, installedAt} atomically; progress(.ready)
        // Cancel => Task cancellation => WhisperKit throws (v1.1.1 release notes: cancelled downloads now throw instead of returning a partial folder).
        // An install and a transcription never overlap: TranscriptionService runs a job only when `model == .ready`.
        fatalError("not implemented")
    }

    private func installedFolder() async throws -> URL? { fatalError("not implemented: read installed.json, validate entries") }
}
