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
    private let download: @Sendable (String, URL, @escaping @Sendable (Double) -> Void) async throws -> URL
    private let prewarm: @Sendable (URL, URL) async throws -> URL
    private var installation: Task<Void, any Error>?

    init(base: URL, variant: String) {
        self.init(base: base, variant: variant, download: { variant, base, progress in
            try await WhisperKit.download(variant: variant, downloadBase: base) { progress($0.fractionCompleted) }
        }, prewarm: { folder, base in try await Self.prepareModel(folder: folder, base: base) })
    }

    init(base: URL, variant: String,
         download: @escaping @Sendable (String, URL, @escaping @Sendable (Double) -> Void) async throws -> URL,
         prewarm: @escaping @Sendable (URL, URL) async throws -> URL) {
        self.base = base; self.variant = variant; self.download = download; self.prewarm = prewarm
    }

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
        guard let marker = try? installedModel() else { throw TranscriberError.modelNotInstalled }
        let kit = try await OfflineWhisperKit(WhisperKitConfig(modelFolder: marker.folder.path, tokenizerFolder: marker.tokenizerFolder,
                                                            verbose: false, prewarm: false, load: false, download: false))
        do { try await kit.loadModels(); return kit }
        catch { await kit.unloadModels(); throw error }
    }

    // MARK: ModelProvider

    /// Installed iff installed.json (written by us AFTER download + prewarm succeeded) names this variant and every
    /// ModelSpec.requiredEntries path exists under its folder. We trust neither WhisperKit's folder layout nor a partial snapshot.
    public func status() async -> ModelStatus { (try? installedModel()) != nil ? .ready : .notInstalled }

    public func install(progress: @escaping @Sendable (ModelStatus) -> Void) async throws {
        if let installation { try await installation.value; return }
        if (try? installedModel()) != nil { progress(.ready); return }
        let task = Task { try await performInstall(progress: progress) }
        installation = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            installation = nil
        } catch { installation = nil; throw error }
    }

    struct InstalledModel: Codable, Sendable {
        let variant: String
        let folder: URL
        let tokenizerFolder: URL
        let installedAt: Date
    }

    private func installedModel() throws -> InstalledModel? {
        let url = base.appendingPathComponent(ModelSpec.installMarker)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let marker = try decoder.decode(InstalledModel.self, from: Data(contentsOf: url))
        guard marker.variant == variant else { return nil }
        try validate(folder: marker.folder, entries: ModelSpec.requiredEntries)
        try validate(folder: marker.tokenizerFolder, entries: ModelSpec.tokenizerEntries)
        return marker
    }

    private func validate(folder: URL, entries: [String]) throws {
        let root = base.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard folder.isFileURL, folder.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw TranscriberError.modelNotInstalled }
        for entry in entries {
            let url = folder.appendingPathComponent(entry)
            guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw TranscriberError.modelNotInstalled }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if entry.hasSuffix(".mlmodelc") {
                guard values.isDirectory == true else { throw TranscriberError.modelNotInstalled }
            } else {
                guard values.isDirectory == false, (values.fileSize ?? 0) > 0 else { throw TranscriberError.modelNotInstalled }
            }
        }
    }

    private func performInstall(progress: @escaping @Sendable (ModelStatus) -> Void) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        progress(.downloading(fraction: 0))
        let folder = try await download(variant, base) { value in
            if value.isFinite { progress(.downloading(fraction: min(1, max(0, value)))) }
        }
        try Task.checkCancellation()
        try validate(folder: folder, entries: ModelSpec.requiredEntries)
        progress(.optimizing)
        try Task.checkCancellation()
        let tokenizer = try await prewarm(folder, base)
        try Task.checkCancellation()
        try validate(folder: folder, entries: ModelSpec.requiredEntries)
        try validate(folder: tokenizer, entries: ModelSpec.tokenizerEntries)
        let marker = InstalledModel(variant: variant, folder: folder, tokenizerFolder: tokenizer, installedAt: Date())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marker)
        try Task.checkCancellation()
        try data.write(to: base.appendingPathComponent(ModelSpec.installMarker), options: .atomic)
        progress(.ready)
    }

    private static func prepareModel(folder: URL, base: URL) async throws -> URL {
        let kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: base,
                                                      verbose: false, prewarm: false, load: false, download: false))
        do {
            try await kit.prewarmModels()
            try Task.checkCancellation()
            // This install-only load resolves the tokenizer into our base as well.
            try await kit.loadModels()
            try Task.checkCancellation()
            let cache = HubApiWrapper(downloadBase: base).localRepoLocation(.init(id: "openai/whisper-\(kit.modelVariant.description)"))
            let tokenizer = FileManager.default.fileExists(atPath: cache.appendingPathComponent("tokenizer.json").path) ? cache : folder
            _ = try await LocalWhisperTokenizer.load(from: tokenizer)
            await kit.unloadModels()
            return tokenizer
        } catch { await kit.unloadModels(); throw error }
    }
}
