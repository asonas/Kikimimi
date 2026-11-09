import Foundation
import RecorderCore
import Testing
@testable import RecorderWhisper

private let variant = "openai_whisper-tiny"

private func modelRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func modelFiles(_ base: URL) throws -> (model: URL, tokenizer: URL) {
    let folder = base.appendingPathComponent("model"), tokenizer = base.appendingPathComponent("tokenizer")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
    for entry in ModelSpec.requiredEntries {
        let url = folder.appendingPathComponent(entry)
        if entry.hasSuffix(".mlmodelc") { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        else { try Data("{}".utf8).write(to: url) }
    }
    for entry in ModelSpec.tokenizerEntries { try Data("{}".utf8).write(to: tokenizer.appendingPathComponent(entry)) }
    return (folder, tokenizer)
}

private func writeMarker(_ base: URL, folder: URL, tokenizer: URL, modelVariant: String = variant) throws {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let marker = WhisperKitEngine.InstalledModel(variant: modelVariant, folder: folder, tokenizerFolder: tokenizer, installedAt: Date(timeIntervalSince1970: 1000))
    try encoder.encode(marker).write(to: base.appendingPathComponent(ModelSpec.installMarker), options: .atomic)
}

private final class InstallEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ModelStatus] = []
    func append(_ value: ModelStatus) { lock.withLock { values.append(value) } }
    var statuses: [ModelStatus] { lock.withLock { values } }
}

private actor InstallerGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor FakeInstaller {
    let folder: URL
    let tokenizer: URL
    var downloads = 0
    var prewarms = 0
    var failDownload = false
    var failPrewarm = false
    var downloadGate: InstallerGate?
    var prewarmGate: InstallerGate?
    init(folder: URL, tokenizer: URL) { self.folder = folder; self.tokenizer = tokenizer }
    func configure(failDownload: Bool = false, failPrewarm: Bool = false, downloadGate: InstallerGate? = nil, prewarmGate: InstallerGate? = nil) {
        self.failDownload = failDownload; self.failPrewarm = failPrewarm
        self.downloadGate = downloadGate; self.prewarmGate = prewarmGate
    }
    func download(_ selected: String, base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        downloads += 1
        #expect(selected == variant)
        progress(-1); progress(0.5); progress(2); progress(.nan)
        await downloadGate?.wait()
        if failDownload { throw CocoaError(.fileReadUnknown) }
        return folder
    }
    func prewarm(_ folder: URL, base: URL) async throws -> URL {
        prewarms += 1
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent(ModelSpec.installMarker).path))
        await prewarmGate?.wait()
        if failPrewarm { throw CocoaError(.fileReadCorruptFile) }
        return tokenizer
    }
}

private func engine(_ base: URL, _ fake: FakeInstaller) -> WhisperKitEngine {
    WhisperKitEngine(base: base, variant: variant,
        download: { try await fake.download($0, base: $1, progress: $2) }, prewarm: { try await fake.prewarm($0, base: $1) })
}

private func waitForGate(_ gate: InstallerGate) async {
    for _ in 0..<10000 { if await gate.entered { return }; await Task.yield() }
    Issue.record("install gate was not reached")
}

@Test func modelStatusRequiresMatchingMarkerAndEveryModelAndTokenizerEntry() async throws {
    let base = try modelRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let (folder, tokenizer) = try modelFiles(base)
    let engine = WhisperKitEngine(base: base, variant: variant)
    #expect(await engine.status() == .notInstalled)
    try writeMarker(base, folder: folder, tokenizer: tokenizer, modelVariant: "wrong-variant")
    #expect(await engine.status() == .notInstalled)
    try writeMarker(base, folder: folder, tokenizer: tokenizer)
    #expect(await engine.status() == .ready)
    for (parent, entries) in [(folder, ModelSpec.requiredEntries), (tokenizer, ModelSpec.tokenizerEntries)] {
        for entry in entries {
            let url = parent.appendingPathComponent(entry), backup = parent.appendingPathComponent(entry + ".held")
            try FileManager.default.moveItem(at: url, to: backup)
            #expect(await engine.status() == .notInstalled)
            try FileManager.default.moveItem(at: backup, to: url)
            #expect(await engine.status() == .ready)
        }
    }
}

@Test func modelStatusRejectsCorruptMarkerAndPathsOutsideBase() async throws {
    let base = try modelRoot(), outside = try modelRoot()
    defer { try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: outside) }
    let (folder, tokenizer) = try modelFiles(outside)
    let engine = WhisperKitEngine(base: base, variant: variant)
    try Data("bad".utf8).write(to: base.appendingPathComponent(ModelSpec.installMarker))
    #expect(await engine.status() == .notInstalled)
    try writeMarker(base, folder: folder, tokenizer: tokenizer)
    #expect(await engine.status() == .notInstalled)
    let link = base.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    try writeMarker(base, folder: link, tokenizer: tokenizer)
    #expect(await engine.status() == .notInstalled)
}

@Test func modelInstallWritesMarkerLastAndReportsBoundedProgress() async throws {
    let base = try modelRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let (folder, tokenizer) = try modelFiles(base)
    let fake = FakeInstaller(folder: folder, tokenizer: tokenizer), events = InstallEvents()
    let engine = engine(base, fake)
    try await engine.install { events.append($0) }
    #expect(events.statuses == [.downloading(fraction: 0), .downloading(fraction: 0), .downloading(fraction: 0.5),
                               .downloading(fraction: 1), .optimizing, .ready])
    #expect(await engine.status() == .ready)
    try await engine.install { events.append($0) }
    #expect(await fake.downloads == 1)
    #expect(await fake.prewarms == 1)
    #expect(engine.identity(language: "ja").model == variant)
}

@Test func modelInstallDownloadAndPrewarmFailureLeaveNoMarker() async throws {
    for downloadFails in [true, false] {
        let base = try modelRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let (folder, tokenizer) = try modelFiles(base)
        let fake = FakeInstaller(folder: folder, tokenizer: tokenizer)
        await fake.configure(failDownload: downloadFails, failPrewarm: !downloadFails)
        let engine = engine(base, fake)
        await #expect(throws: CocoaError.self) { try await engine.install { _ in } }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent(ModelSpec.installMarker).path))
        #expect(await engine.status() == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }
}

@Test func modelInstallRejectsMissingModelBeforePrewarmAndMissingTokenizerAfterPrewarm() async throws {
    for missingModel in [true, false] {
        let base = try modelRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let (folder, tokenizer) = try modelFiles(base)
        try FileManager.default.removeItem(at: (missingModel ? folder : tokenizer).appendingPathComponent(missingModel ? "config.json" : "tokenizer.json"))
        let fake = FakeInstaller(folder: folder, tokenizer: tokenizer)
        let engine = engine(base, fake)
        await #expect(throws: (any Error).self) { try await engine.install { _ in } }
        #expect(await fake.prewarms == (missingModel ? 0 : 1))
        #expect(await engine.status() == .notInstalled)
    }
}

@Test func modelInstallCancellationDuringDownloadRetainsCacheAndAllowsRetry() async throws {
    let base = try modelRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let (folder, tokenizer) = try modelFiles(base)
    let fake = FakeInstaller(folder: folder, tokenizer: tokenizer), gate = InstallerGate()
    await fake.configure(downloadGate: gate)
    let engine = engine(base, fake)
    let task = Task { try await engine.install { _ in } }
    await waitForGate(gate)
    task.cancel(); await gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await engine.status() == .notInstalled)
    #expect(await fake.prewarms == 0)
    #expect(FileManager.default.fileExists(atPath: folder.path))
    await fake.configure()
    try await engine.install { _ in }
    #expect(await engine.status() == .ready)
    #expect(await fake.downloads == 2)
}

@Test func modelInstallCancellationDuringPrewarmDoesNotMarkReady() async throws {
    let base = try modelRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let (folder, tokenizer) = try modelFiles(base)
    let fake = FakeInstaller(folder: folder, tokenizer: tokenizer), gate = InstallerGate(), events = InstallEvents()
    await fake.configure(prewarmGate: gate)
    let engine = engine(base, fake)
    let task = Task { try await engine.install { events.append($0) } }
    await waitForGate(gate)
    task.cancel(); await gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!events.statuses.contains(.ready))
    #expect(await engine.status() == .notInstalled)
}

@Test func modelInstallConcurrentRequestsShareOneDownload() async throws {
    let base = try modelRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let (folder, tokenizer) = try modelFiles(base)
    let fake = FakeInstaller(folder: folder, tokenizer: tokenizer), gate = InstallerGate()
    await fake.configure(downloadGate: gate)
    let engine = engine(base, fake)
    let first = Task { try await engine.install { _ in } }
    await waitForGate(gate)
    let second = Task { try await engine.install { _ in } }
    await gate.release()
    try await first.value; try await second.value
    #expect(await fake.downloads == 1)
    #expect(await fake.prewarms == 1)
}

@Test func modelMissingTokenizerFailsTranscriptionWithoutDownload() async throws {
    let base = try modelRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let (folder, tokenizer) = try modelFiles(base)
    try writeMarker(base, folder: folder, tokenizer: tokenizer)
    try FileManager.default.removeItem(at: tokenizer.appendingPathComponent("tokenizer.json"))
    let fake = FakeInstaller(folder: folder, tokenizer: tokenizer), engine = engine(base, fake)
    await #expect(throws: TranscriberError.modelNotInstalled) {
        try await engine.transcribe(.init(audio: .init(), language: "ja"), progress: { _, _ in })
    }
    #expect(await fake.downloads == 0)
    #expect(await fake.prewarms == 0)
}

@Test func localTokenizerMissingOrCorruptFilesFailWithoutHubFallback() async throws {
    let base = try modelRoot(); defer { try? FileManager.default.removeItem(at: base) }
    await #expect(throws: (any Error).self) { try await LocalWhisperTokenizer.load(from: base) }
    try Data("bad".utf8).write(to: base.appendingPathComponent("tokenizer.json"))
    try Data("{}".utf8).write(to: base.appendingPathComponent("tokenizer_config.json"))
    await #expect(throws: (any Error).self) { try await LocalWhisperTokenizer.load(from: base) }
}

@Test func localTokenizerLoadsSyntheticFilesAndPreservesTokenGroups() async throws {
    let base = try modelRoot(); defer { try? FileManager.default.removeItem(at: base) }
    let specials = ["<|endoftext|>", "<|en|>", "<|ja|>", "<|nospeech|>", "<|notimestamps|>",
                    "<|startofprev|>", "<|startoftranscript|>", "<|transcribe|>", "<|translate|>", "<|0.00|>"]
    // Complete GPT-2 byte alphabet, with no merges, to exercise multi-token Japanese UTF-8.
    let direct = Array(33...126) + Array(161...172) + Array(174...255)
    var alphabet = Dictionary(uniqueKeysWithValues: direct.map { ($0, $0) })
    var next = 256
    for byte in 0..<256 where alphabet[byte] == nil { alphabet[byte] = next; next += 1 }
    var vocab = Dictionary(uniqueKeysWithValues: alphabet.map { (String(UnicodeScalar($0.value)!), $0.key) })
    for (index, token) in specials.enumerated() { vocab[token] = index + 256 }
    let data: [String: Any] = [
        "model": ["type": "BPE", "vocab": vocab, "merges": [], "unk_token": "<|endoftext|>"],
        "added_tokens": specials.enumerated().map { ["id": $0.offset + 256, "content": $0.element, "special": true] as [String: Any] },
        "pre_tokenizer": ["type": "ByteLevel", "add_prefix_space": false, "trim_offsets": true, "use_regex": true],
        "decoder": ["type": "ByteLevel"]
    ]
    try JSONSerialization.data(withJSONObject: data).write(to: base.appendingPathComponent("tokenizer.json"))
    try Data(#"{"tokenizer_class":"WhisperTokenizer","clean_up_tokenization_spaces":false}"#.utf8)
        .write(to: base.appendingPathComponent("tokenizer_config.json"))
    let tokenizer = try await LocalWhisperTokenizer.load(from: base)
    #expect(tokenizer.specialTokens.endToken == 256)
    #expect(tokenizer.allLanguageTokens == [257, 258])
    for text in ["ab ab", "はい、日本語です。", "a�日本語b"] {
        let ids = tokenizer.encode(text: text)
        #expect(tokenizer.decode(tokens: ids) == text)
        let split = tokenizer.splitToWordTokens(tokenIds: ids)
        #expect(split.words.joined() == text)
        #expect(split.wordTokens.flatMap { $0 } == ids)
    }
}
