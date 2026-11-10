import Foundation
import RecorderCore
import Testing
@testable import RecorderWhisper

private let testSegment = EngineSegmentDTO(start: 8, end: 12, text: "<|ja|> 録音テスト ",
    avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.2)

private actor TranscriptionGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct ProgressEvent: Sendable, Equatable {
    let track: Track
    let fraction: Double
}

private final class ProgressEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProgressEvent] = []
    func append(_ track: Track, _ fraction: Double) { lock.withLock { events.append(.init(track: track, fraction: fraction)) } }
    var values: [ProgressEvent] { lock.withLock { events } }
}

private actor ScriptedWhisperSession: WhisperSession {
    var urls: [URL] = []
    var languages: [String] = []
    var unloads = 0
    var loads = 0
    let gate: TranscriptionGate?
    let failure: TranscriberError?
    var fractions: [Double]
    init(gate: TranscriptionGate? = nil, failure: TranscriberError? = nil, fractions: [Double] = []) {
        self.gate = gate; self.failure = failure; self.fractions = fractions
    }
    func loaded() { loads += 1 }
    func transcribe(_ url: URL, language: String) async throws -> [EngineSegmentDTO] {
        urls.append(url); languages.append(language)
        await gate?.wait()
        try Task.checkCancellation()
        if let failure { throw failure }
        return [testSegment]
    }
    func fractionCompleted() -> Double { fractions.isEmpty ? 0.5 : fractions.removeFirst() }
    func unload() { unloads += 1 }
}

private func eventually(_ predicate: () async -> Bool) async {
    let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(3)
    while clock.now < deadline { if await predicate() { return }; await Task.yield() }
    Issue.record("Timed out waiting for fake session")
}

private func installedTestModel() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("model"), tokenizer = root.appendingPathComponent("tokenizer")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
    for entry in ModelSpec.requiredEntries {
        let url = folder.appendingPathComponent(entry)
        if entry.hasSuffix(".mlmodelc") { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        else { try Data("{}".utf8).write(to: url) }
    }
    for entry in ModelSpec.tokenizerEntries { try Data("{}".utf8).write(to: tokenizer.appendingPathComponent(entry)) }
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(WhisperKitEngine.InstalledModel(variant: "test", folder: "model",
        tokenizerFolder: "tokenizer", installedAt: Date())).write(to: root.appendingPathComponent(ModelSpec.installMarker))
    return root
}

private func testEngine(_ root: URL, _ session: ScriptedWhisperSession) -> WhisperKitEngine {
    WhisperKitEngine(base: root, variant: "test", download: { _, _, _ in
        Issue.record("Transcription must not download"); throw TranscriberError.modelNotInstalled
    }, prewarm: { _, _ in
        Issue.record("Transcription must not install"); throw TranscriberError.modelNotInstalled
    }, sampleInterval: .milliseconds(1), sessionLoader: { _, _ in await session.loaded(); return session })
}

private let remoteURL = URL(fileURLWithPath: "/tmp/remote.m4a")
private let selfURL = URL(fileURLWithPath: "/tmp/self.m4a")
private let bothTracks = TranscribeRequest(audio: .init(me: selfURL, remote: remoteURL), language: "ja")

@Test func whisperSessionLoadsOnceRunsTracksSequentiallyCopiesDTOAndUnloads() async throws {
    let root = try installedTestModel(); defer { try? FileManager.default.removeItem(at: root) }
    let session = ScriptedWhisperSession(), engine = testEngine(root, session), events = ProgressEvents()
    let result = try await engine.transcribe(bothTracks, progress: events.append)
    #expect(result[.remote] == [testSegment]); #expect(result[.me] == [testSegment])
    #expect(await session.urls == [remoteURL, selfURL]); #expect(await session.languages == ["ja", "ja"])
    #expect(await session.loads == 1); #expect(await session.unloads == 1); #expect(await !engine.isModelLoaded)
    for track in [Track.remote, .me] {
        let samples = events.values.filter { $0.track == track }.map(\.fraction)
        #expect(samples.first == 0); #expect(samples.last == 1)
    }
    let firstSelf = try #require(events.values.firstIndex { $0.track == .me })
    #expect(events.values[..<firstSelf].allSatisfy { $0.track == .remote })
    #expect(events.values[firstSelf...].allSatisfy { $0.track == .me })
}

@Test func whisperSessionFailureUnloadsAndDoesNotStartNextTrack() async throws {
    let root = try installedTestModel(); defer { try? FileManager.default.removeItem(at: root) }
    let session = ScriptedWhisperSession(failure: .engine("scripted failure")), engine = testEngine(root, session)
    await #expect(throws: TranscriberError.engine("scripted failure")) {
        try await engine.transcribe(bothTracks) { _, _ in }
    }
    #expect(await session.urls == [remoteURL]); #expect(await session.unloads == 1); #expect(await !engine.isModelLoaded)
}

@Test func whisperSessionCancellationUnloadsBeforeReturningAndStopsNextTrack() async throws {
    let root = try installedTestModel(); defer { try? FileManager.default.removeItem(at: root) }
    let gate = TranscriptionGate(), session = ScriptedWhisperSession(gate: gate)
    let engine = testEngine(root, session), events = ProgressEvents()
    let task = Task { try await engine.transcribe(bothTracks, progress: events.append) }
    await eventually { await gate.entered }
    #expect(await engine.isModelLoaded)
    task.cancel(); await gate.release()
    await #expect(throws: TranscriberError.cancelled) { try await task.value }
    #expect(await session.urls == [remoteURL]); #expect(await session.unloads == 1); #expect(await !engine.isModelLoaded)
    #expect(!events.values.contains { $0.fraction == 1 })
}

@Test func whisperSessionCancelledBeforeLoadDoesNotLoadModel() async throws {
    let root = try installedTestModel(); defer { try? FileManager.default.removeItem(at: root) }
    let gate = TranscriptionGate(), session = ScriptedWhisperSession(), engine = testEngine(root, session)
    let task = Task { await gate.wait(); return try await engine.transcribe(bothTracks) { _, _ in } }
    await eventually { await gate.entered }; task.cancel(); await gate.release()
    await #expect(throws: TranscriberError.cancelled) { try await task.value }
    #expect(await session.loads == 0); #expect(await session.unloads == 0); #expect(await !engine.isModelLoaded)
}

@Test func whisperSessionProgressIsFiniteMonotoneAndStopsBeforeReturning() async throws {
    let root = try installedTestModel(); defer { try? FileManager.default.removeItem(at: root) }
    let gate = TranscriptionGate()
    let session = ScriptedWhisperSession(gate: gate, fractions: [-1, 0.4, .nan, .infinity, 0.1, 2])
    let engine = testEngine(root, session), events = ProgressEvents()
    let task = Task { try await engine.transcribe(.init(audio: .init(remote: remoteURL), language: "ja"), progress: events.append) }
    await eventually { events.values.contains { $0.fraction == 1.0.nextDown } }
    #expect(!events.values.contains { $0.fraction == 1 })
    await gate.release(); _ = try await task.value
    let fractions = events.values.map(\.fraction)
    #expect(fractions.allSatisfy { $0.isFinite && (0...1).contains($0) })
    #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(fractions.first == 0); #expect(fractions.last == 1); #expect(fractions.contains(0.4))
    let snapshot = events.values
    await Task.yield()
    #expect(events.values == snapshot); #expect(await session.unloads == 1)
}

@Test func whisperSessionMissingModelFailsWithoutLoadingOrDownloading() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session = ScriptedWhisperSession(), engine = testEngine(root, session)
    await #expect(throws: TranscriberError.modelNotInstalled) { try await engine.transcribe(bothTracks) { _, _ in } }
    #expect(await session.loads == 0); #expect(await !engine.isModelLoaded)
}

@Test func whisperSessionCancellationDuringLoadUnloadsWithoutStartingTrack() async throws {
    let root = try installedTestModel(); defer { try? FileManager.default.removeItem(at: root) }
    let gate = TranscriptionGate(), session = ScriptedWhisperSession()
    let engine = WhisperKitEngine(base: root, variant: "test", download: { _, _, _ in
        throw TranscriberError.modelNotInstalled
    }, prewarm: { _, _ in throw TranscriberError.modelNotInstalled }, sessionLoader: { _, _ in
        await session.loaded(); await gate.wait(); return session
    })
    let task = Task { try await engine.transcribe(bothTracks) { _, _ in } }
    await eventually { await gate.entered }; task.cancel(); await gate.release()
    await #expect(throws: TranscriberError.cancelled) { try await task.value }
    #expect(await session.urls.isEmpty); #expect(await session.unloads == 1); #expect(await !engine.isModelLoaded)
}

@Test func whisperSessionRejectsOverlappingCallsWithoutUnloadingActiveSession() async throws {
    let root = try installedTestModel(); defer { try? FileManager.default.removeItem(at: root) }
    let gate = TranscriptionGate(), session = ScriptedWhisperSession(gate: gate), engine = testEngine(root, session)
    let task = Task { try await engine.transcribe(.init(audio: .init(remote: remoteURL), language: "ja")) { _, _ in } }
    await eventually { await gate.entered }
    await #expect(throws: TranscriberError.engine("Transcription already active")) {
        try await engine.transcribe(bothTracks) { _, _ in }
    }
    #expect(await session.loads == 1); #expect(await session.unloads == 0); #expect(await engine.isModelLoaded)
    await gate.release(); _ = try await task.value
    #expect(await session.unloads == 1)
}
