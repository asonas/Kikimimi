import Foundation
import Testing
@testable import RecorderCore

private let transcriptDate = Date(timeIntervalSince1970: 1000)
private let identity = TranscriberIdentity(engine: "fake", engineVersion: "1", model: "fake", language: "ja", chunking: "vad")
private let defaultOutput = PerTrack<[EngineSegmentDTO]>(
    me: [.init(start: 1, end: 2, text: "<|ja|> はい、\n藤原です。", avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1)],
    remote: [.init(start: 0, end: 1, text: "お願いします。", avgLogprob: -0.3, noSpeechProb: 0.01, compressionRatio: 1)])

private func savedSegments(_ text: String) -> SegmentsFile {
    .init(schemaVersion: 1, createdAt: transcriptDate, transcriber: identity, tracks: .init(me: .transcribed),
          segments: [.init(start: 0, end: 1, speaker: .me, text: text, avgLogprob: -0.2, noSpeechProb: 0, compressionRatio: 1)])
}

private func transcriptionRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func finalizedSession(_ store: SessionStore) async throws -> SessionRef {
    let (ref, lease) = try await store.create(.init(company: "Acme", remote: .allSystemAudio),
        mic: .mic(deviceUID: "uid", deviceName: "Mic", channel: 1, deviceChannels: 1), remote: .allSystemAudio,
        app: .init(version: "1", build: "1", os: "test"))
    try await store.update(ref) {
        $0.capture = .finished(endedAt: transcriptDate.addingTimeInterval(5), reason: .user)
        $0.tracks.me?.firstSampleHostSeconds = 100.5
        $0.tracks.remote?.firstSampleHostSeconds = 100
        $0.tracks.me?.audio = .init(file: ref.folder.audio(.me).lastPathComponent, sampleRate: 48_000, frames: 192_000, peakDBFS: -6)
        $0.tracks.remote?.audio = .init(file: ref.folder.audio(.remote).lastPathComponent, sampleRate: 48_000, frames: 96_000, peakDBFS: -6)
    }
    for track in Track.allCases { try Data([1]).write(to: ref.folder.audio(track)) }
    lease.release()
    return ref
}

private actor FakeModels: ModelProvider {
    var ready: Bool
    var installs = 0
    var delay = false
    var failure = false
    var gate: CheckedContinuation<Void, Never>?
    init(ready: Bool = true) { self.ready = ready }
    func status() async -> ModelStatus { ready ? .ready : .notInstalled }
    func configure(delay: Bool = false, failure: Bool = false) { self.delay = delay; self.failure = failure }
    func release() { gate?.resume(); gate = nil }
    func install(progress: @escaping @Sendable (ModelStatus) -> Void) async throws {
        installs += 1
        progress(.downloading(fraction: 0.5))
        if delay { await withCheckedContinuation { gate = $0 } }
        progress(.optimizing)
        if failure { throw TranscriberError.engine("install failed") }
        ready = true
        progress(.ready)
    }
}

private actor FakeSessionTranscriber: Transcriber {
    var requests: [TranscribeRequest] = []
    var output = defaultOutput
    var failure: TranscriberError?
    var blocks = false
    var ignoresCancellation = false
    var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    var callbacks: [Int: @Sendable (Track, Double) -> Void] = [:]
    var active = 0
    var maxActive = 0
    nonisolated func identity(language: String) -> TranscriberIdentity {
        .init(engine: "fake", engineVersion: "1", model: "fake", language: language, chunking: "vad")
    }
    func configure(blocks: Bool = false, ignoresCancellation: Bool = false, failure: TranscriberError? = nil,
                   output: PerTrack<[EngineSegmentDTO]> = defaultOutput) {
        self.blocks = blocks; self.ignoresCancellation = ignoresCancellation; self.failure = failure; self.output = output
    }
    func release(_ call: Int) { gates.removeValue(forKey: call)?.resume() }
    func emit(_ call: Int, _ track: Track, _ fraction: Double) { callbacks[call]?(track, fraction) }
    func transcribe(_ request: TranscribeRequest, progress: @escaping @Sendable (Track, Double) -> Void) async throws -> PerTrack<[EngineSegmentDTO]> {
        requests.append(request)
        let call = requests.count, ignore = ignoresCancellation
        callbacks[call] = progress
        active += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        if blocks {
            await withTaskCancellationHandler {
                await withCheckedContinuation { gates[call] = $0 }
            } onCancel: {
                if !ignore { Task { await self.release(call) } }
            }
        }
        if !ignore { try Task.checkCancellation() }
        if let failure { throw failure }
        return output
    }
}

@MainActor private func waitFor(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<20000 { if await condition() { return }; await Task.yield() }
    Issue.record("transcription did not reach expected state")
}

@MainActor private func jobState(_ service: TranscriptionService, _ ref: SessionRef) -> TranscriptionJobState? {
    service.jobs.first { $0.id == ref.id }?.state
}

@Test func transcriptionScheduleTruthTable() {
    let ref = SessionRef(id: UUID(), folder: .init(url: URL(fileURLWithPath: "/tmp/schedule")))
    let states: [[TranscriptionJobState]] = [[], [.queued], [.waiting(.modelNotReady)], [.running(fraction: 0.5)], [.failed("bad"), .done], [.done, .queued]]
    for states in states {
        let jobs = states.map { TranscriptionJob(ref: ref, state: $0) }
        for recording in [false, true] {
            for ready in [false, true] {
                let actual = TranscriptionSchedule.next(jobs: jobs, recordingActive: recording, modelReady: ready)
                let hasRunning = states.contains { if case .running = $0 { true } else { false } }
                let hasPending = states.contains { switch $0 { case .queued, .waiting: true; default: false } }
                let expected: TranscriptionSchedule.Decision
                if recording { expected = hasRunning ? .cancelRunning : .wait(.recordingInProgress) }
                else if !ready { expected = .wait(.modelNotReady) }
                else if hasRunning { expected = .idle }
                else { expected = hasPending ? .run(ref.id) : .idle }
                #expect(actual == expected)
            }
        }
    }
}

@Test @MainActor func transcriptionEnqueueIsVisibleSynchronouslyAndNoAutomaticEnqueueOccurs() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    let engine = FakeSessionTranscriber(), models = FakeModels(ready: false)
    let service = TranscriptionService(store: store, transcriber: engine, models: models, language: { "ja" })
    await waitFor { service.model == .notInstalled }
    #expect(service.jobs.isEmpty)
    service.enqueue(ref)
    #expect(service.jobs.count == 1)
    #expect(jobState(service, ref) == .waiting(.modelNotReady))
    service.enqueue(ref)
    #expect(service.jobs.count == 1)
    #expect(await engine.requests.isEmpty)
}

@Test @MainActor func transcriptionNormalizesMergesAndSavesWholeSession() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    let engine = FakeSessionTranscriber()
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    service.enqueue(ref)
    #expect(service.jobs.first?.id == ref.id)
    await waitFor { jobState(service, ref) == .done }
    let file = try #require(try await store.segments(of: ref))
    #expect(file.tracks == .init(me: .transcribed, remote: .transcribed))
    #expect(file.segments.map(\.speaker) == [.remote, .me])
    #expect(file.segments.map(\.start) == [0, 1.5])
    #expect(file.segments.last?.text == "はい、 藤原です。")
    #expect(file.transcriber == identity)
    #expect(try String(contentsOf: ref.folder.transcript, encoding: .utf8).contains("[00:00:01 自分] はい、 藤原です。"))
    #expect(await engine.requests.count == 1)
}

@Test @MainActor func transcriptionSkipsSilentAndMissingTracksWithoutCallingEngine() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.update(ref) { $0.tracks.me?.audio?.peakDBFS = -70; $0.tracks.remote?.audio = nil }
    let engine = FakeSessionTranscriber()
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    service.enqueue(ref)
    await waitFor { jobState(service, ref) == .done }
    let file = try #require(try await store.segments(of: ref))
    #expect(file.tracks == .init(me: .skippedSilent, remote: .skippedNoAudio))
    #expect(file.segments.isEmpty)
    #expect(await engine.requests.isEmpty)
}

@Test @MainActor func transcriptionOnlyRequestsNonsilentPresentTrack() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.update(ref) { $0.tracks.me?.audio?.peakDBFS = -80 }
    let engine = FakeSessionTranscriber()
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    service.enqueue(ref)
    await waitFor { jobState(service, ref) == .done }
    let request = try #require(await engine.requests.first)
    #expect(request.audio == .init(remote: ref.folder.audio(.remote)))
    #expect(try await store.segments(of: ref)?.tracks == .init(me: .skippedSilent, remote: .transcribed))
}

@Test @MainActor func transcriptionProgressIsWeightedAndMonotone() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    let engine = FakeSessionTranscriber(); await engine.configure(blocks: true)
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    service.enqueue(ref)
    await waitFor { await engine.gates[1] != nil }
    await engine.emit(1, .remote, 0.5)
    await waitFor { jobState(service, ref) == .running(fraction: 1.0 / 6) }
    await engine.emit(1, .me, 1)
    await waitFor {
        if case .running(let value) = jobState(service, ref) { return abs(value - 5.0 / 6) < 0.0001 }; return false
    }
    await engine.emit(1, .remote, .nan); await engine.emit(1, .me, 0)
    await engine.release(1)
    await waitFor { jobState(service, ref) == .done }
}

@Test @MainActor func transcriptionRecordingPreemptionWaitsForCancellationAndPreservesFIFO() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), first = try await finalizedSession(store), second = try await finalizedSession(store)
    let engine = FakeSessionTranscriber(); await engine.configure(blocks: true, ignoresCancellation: true)
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    service.enqueue(first); service.enqueue(second)
    await waitFor { await engine.gates[1] != nil }
    service.setRecordingActive(true)
    await engine.release(1)
    await waitFor { jobState(service, first) == .waiting(.recordingInProgress) }
    #expect(service.jobs.map(\.id) == [first.id, second.id])
    #expect(!FileManager.default.fileExists(atPath: first.folder.segments.path))
    #expect(!FileManager.default.fileExists(atPath: first.folder.transcript.path))
    #expect(await engine.requests.count == 1)
    service.setRecordingActive(false)
    await waitFor { await engine.gates[2] != nil }
    #expect(await engine.requests[1].audio.me == first.folder.audio(.me))
    await engine.emit(1, .me, 1) // A late callback from the cancelled generation must not affect this run.
    await engine.emit(2, .remote, 0.5)
    await waitFor { jobState(service, first) == .running(fraction: 1.0 / 6) }
    await engine.release(2)
    await waitFor { await engine.gates[3] != nil }
    #expect(await engine.requests[2].audio.me == second.folder.audio(.me))
    await engine.release(3)
    await waitFor { jobState(service, second) == .done }
    #expect(await engine.maxActive == 1)
}

@Test @MainActor func transcriptionReportsOnlySavedTranscriptsWithTheirOrigin() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root)
    let recorded = try await finalizedSession(store), retried = try await finalizedSession(store)
    let failed = try await finalizedSession(store), cancelled = try await finalizedSession(store)
    let engine = FakeSessionTranscriber()
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    var reports: [(UUID, TranscriptionOrigin)] = []
    service.onTranscribed = { reports.append(($0.id, $1)) }

    service.enqueue(recorded, origin: .newRecording); service.enqueue(retried)
    await waitFor { jobState(service, recorded) == .done && jobState(service, retried) == .done }
    #expect(reports.map(\.0) == [recorded.id, retried.id])
    #expect(reports.map(\.1) == [.newRecording, .manual])

    await engine.configure(failure: .engine("fake failure"))
    service.enqueue(failed, origin: .newRecording)
    await waitFor { if case .failed = jobState(service, failed) { return true }; return false }
    await engine.configure(blocks: true)
    service.enqueue(cancelled, origin: .newRecording)
    await waitFor { await engine.gates[4] != nil }
    service.cancel(cancelled)
    await waitFor { jobState(service, cancelled) == nil }
    #expect(reports.count == 2)
}

@Test @MainActor func transcriptionManualCancelRemovesRunningAndQueuedJobsWithoutFiles() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), first = try await finalizedSession(store), second = try await finalizedSession(store)
    let engine = FakeSessionTranscriber(); await engine.configure(blocks: true)
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    service.enqueue(first); service.enqueue(second)
    await waitFor { await engine.gates[1] != nil }
    service.cancel(second); service.cancel(first)
    await waitFor { service.jobs.isEmpty }
    #expect(await engine.requests.count == 1)
    #expect(!FileManager.default.fileExists(atPath: first.folder.segments.path))
}

@Test @MainActor func transcriptionFailurePreservesPreviousFilesAndRequiresExplicitRetry() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.saveTranscription(ref, savedSegments("previous"))
    let previous = try Data(contentsOf: ref.folder.segments), markdown = try Data(contentsOf: ref.folder.transcript)
    let engine = FakeSessionTranscriber(); await engine.configure(failure: .engine("fake failure"))
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    service.enqueue(ref)
    await waitFor { if case .failed = jobState(service, ref) { return true }; return false }
    #expect(try Data(contentsOf: ref.folder.segments) == previous)
    #expect(try Data(contentsOf: ref.folder.transcript) == markdown)
    service.setRecordingActive(false)
    #expect(await engine.requests.count == 1)
    await engine.configure()
    service.enqueue(ref)
    await waitFor { jobState(service, ref) == .done }
    #expect(try Data(contentsOf: ref.folder.transcriptBackup) == markdown)
}

@Test @MainActor func transcriptionMissingModelWaitsAndInstallResumesOnce() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    let engine = FakeSessionTranscriber(), models = FakeModels(ready: false)
    await models.configure(delay: true)
    let service = TranscriptionService(store: store, transcriber: engine, models: models, language: { "ja" })
    service.enqueue(ref)
    #expect(jobState(service, ref) == .waiting(.modelNotReady))
    let install = Task { await service.installModel() }
    await waitFor { await models.gate != nil }
    let duplicate = Task { await service.installModel() }
    #expect(await engine.requests.isEmpty)
    await models.release(); await install.value; await duplicate.value
    await waitFor { jobState(service, ref) == .done }
    #expect(await models.installs == 1)
    await service.installModel()
    #expect(await models.installs == 1)
}

@Test @MainActor func transcriptionMissingAudioFailsWithoutReplacingPreviousSegments() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.saveTranscription(ref, savedSegments("previous"))
    let previous = try Data(contentsOf: ref.folder.segments)
    try FileManager.default.removeItem(at: ref.folder.audio(.me))
    let engine = FakeSessionTranscriber()
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    service.enqueue(ref)
    await waitFor { if case .failed = jobState(service, ref) { return true }; return false }
    #expect(try Data(contentsOf: ref.folder.segments) == previous)
    #expect(await engine.requests.isEmpty)
}

@Test func transcriptionStoreBacksUpOnePreviousMarkdownAndRerendersWithoutChangingSegments() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.saveTranscription(ref, savedSegments("first"))
    let first = try Data(contentsOf: ref.folder.transcript)
    try await store.saveTranscription(ref, savedSegments("second"))
    #expect(try Data(contentsOf: ref.folder.transcriptBackup) == first)
    let second = try Data(contentsOf: ref.folder.transcript)
    try await store.saveTranscription(ref, savedSegments("third"))
    #expect(try Data(contentsOf: ref.folder.transcriptBackup) == second)
    let segments = try Data(contentsOf: ref.folder.segments)
    try FileManager.default.removeItem(at: ref.folder.transcript)
    try await store.rerenderTranscript(ref)
    #expect(try Data(contentsOf: ref.folder.segments) == segments)
    #expect(try Data(contentsOf: ref.folder.transcriptBackup) == second)
    #expect(try String(contentsOf: ref.folder.transcript, encoding: .utf8).contains("third"))
}

@Test func transcriptionStoreRejectsHeldLeaseWithoutWriting() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    let lease = try #require(CaptureLease.acquire(ref.folder.lock)); defer { lease.release() }
    await #expect(throws: CocoaError.self) { try await store.saveTranscription(ref, savedSegments("new")) }
    await #expect(throws: CocoaError.self) { try await store.rerenderTranscript(ref) }
    #expect(!FileManager.default.fileExists(atPath: ref.folder.segments.path))
}

@Test func transcriptionStoreRejectsBrokenMetaWithoutWriting() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.saveTranscription(ref, savedSegments("previous"))
    let previous = try Data(contentsOf: ref.folder.segments), data = Data("bad".utf8)
    try data.write(to: ref.folder.meta)
    await #expect(throws: (any Error).self) { try await store.saveTranscription(ref, savedSegments("new")) }
    await #expect(throws: (any Error).self) { try await store.rerenderTranscript(ref) }
    #expect(try Data(contentsOf: ref.folder.segments) == previous)
    #expect(try Data(contentsOf: ref.folder.meta) == data)
}

@Test func transcriptionStoreRejectsNewerMetaWithoutWriting() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.saveTranscription(ref, savedSegments("previous"))
    let previous = try Data(contentsOf: ref.folder.segments), data = Data(#"{"schemaVersion":2}"#.utf8)
    try data.write(to: ref.folder.meta)
    await #expect(throws: SessionMetaError.self) { try await store.saveTranscription(ref, savedSegments("new")) }
    await #expect(throws: SessionMetaError.self) { try await store.rerenderTranscript(ref) }
    #expect(try Data(contentsOf: ref.folder.segments) == previous)
    #expect(try Data(contentsOf: ref.folder.meta) == data)
}

@Test func transcriptionStoreRejectsNewerSegmentsWithoutWriting() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.saveTranscription(ref, savedSegments("previous"))
    let markdown = try Data(contentsOf: ref.folder.transcript)
    let future = Data(#"{"schemaVersion":2,"future":"keep"}"#.utf8)
    try future.write(to: ref.folder.segments)
    await #expect(throws: CocoaError.self) { try await store.saveTranscription(ref, savedSegments("new")) }
    await #expect(throws: (any Error).self) { try await store.rerenderTranscript(ref) }
    #expect(try Data(contentsOf: ref.folder.segments) == future)
    #expect(try Data(contentsOf: ref.folder.transcript) == markdown)
}

@Test @MainActor func transcriptionUnexpectedEngineCancellationFailsWithoutRetryLoop() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    let engine = FakeSessionTranscriber(); await engine.configure(failure: .cancelled)
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    service.enqueue(ref)
    await waitFor { if case .failed = jobState(service, ref) { return true }; return false }
    service.setRecordingActive(false)
    #expect(await engine.requests.count == 1)
    #expect(!FileManager.default.fileExists(atPath: ref.folder.segments.path))
}

@Test @MainActor func transcriptionProgressIgnoresSkippedTrack() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.update(ref) { $0.tracks.me?.audio?.peakDBFS = -80 }
    let engine = FakeSessionTranscriber(); await engine.configure(blocks: true)
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    service.enqueue(ref)
    await waitFor { await engine.gates[1] != nil }
    await engine.emit(1, .me, 1)
    await engine.emit(1, .remote, 0.5)
    await waitFor { jobState(service, ref) == .running(fraction: 0.5) }
    await engine.release(1)
    await waitFor { jobState(service, ref) == .done }
}

@Test @MainActor func transcriptionEngineModelMissingWaitsUntilInstall() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    let engine = FakeSessionTranscriber(); await engine.configure(failure: .modelNotInstalled)
    let models = FakeModels()
    let service = TranscriptionService(store: store, transcriber: engine, models: models, language: { "ja" })
    service.enqueue(ref)
    await waitFor {
        let count = await engine.requests.count
        return service.model == .notInstalled && jobState(service, ref) == .waiting(.modelNotReady) && count == 1
    }
    await engine.configure()
    await service.installModel()
    await waitFor { jobState(service, ref) == .done }
    #expect(await engine.requests.count == 2)
}

@Test @MainActor func transcriptionInstallFailureLeavesJobsWaitingAndPreviousFilesUntouched() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.saveTranscription(ref, savedSegments("previous"))
    let previous = try Data(contentsOf: ref.folder.segments)
    let engine = FakeSessionTranscriber(), models = FakeModels(ready: false)
    await models.configure(failure: true)
    let service = TranscriptionService(store: store, transcriber: engine, models: models, language: { "ja" })
    service.enqueue(ref)
    await service.installModel()
    guard case .failed = service.model else { Issue.record("expected install failure"); return }
    #expect(jobState(service, ref) == .waiting(.modelNotReady))
    #expect(await engine.requests.isEmpty)
    #expect(try Data(contentsOf: ref.folder.segments) == previous)
}

@Test @MainActor func transcriptionMissingRequestedEngineOutputFailsWithoutLosingPreviousResult() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.saveTranscription(ref, savedSegments("previous"))
    let previous = try Data(contentsOf: ref.folder.segments)
    let engine = FakeSessionTranscriber(); await engine.configure(output: .init(remote: defaultOutput.remote))
    let service = TranscriptionService(store: store, transcriber: engine, models: FakeModels(), language: { "ja" })
    service.enqueue(ref)
    await waitFor { if case .failed = jobState(service, ref) { return true }; return false }
    #expect(try Data(contentsOf: ref.folder.segments) == previous)
}

@Test func transcriptionStoreCancellationBeforeCommitLeavesPreviousFiles() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root), ref = try await finalizedSession(store)
    try await store.saveTranscription(ref, savedSegments("previous"))
    let previous = try Data(contentsOf: ref.folder.segments), markdown = try Data(contentsOf: ref.folder.transcript)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await store.saveTranscription(ref, savedSegments("cancelled"))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: ref.folder.segments) == previous)
    #expect(try Data(contentsOf: ref.folder.transcript) == markdown)
    #expect(!FileManager.default.fileExists(atPath: ref.folder.transcriptBackup.path))
}

@Test func transcriptionStoreCancellationAfterCommitBeginsStillFinishes() async throws {
    let root = try transcriptionRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root, atomicWrite: { data, url in
        if url.lastPathComponent == SessionFolder(url: root).segments.lastPathComponent {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        try data.write(to: url, options: .atomic)
    })
    let ref = try await finalizedSession(store)
    try Data("previous".utf8).write(to: ref.folder.transcript)
    let task = Task { try await store.saveTranscription(ref, savedSegments("committed")) }
    try await task.value
    #expect(task.isCancelled)
    #expect(try await store.segments(of: ref)?.segments.first?.text == "committed")
    #expect(try String(contentsOf: ref.folder.transcript, encoding: .utf8).contains("committed"))
    #expect(try String(contentsOf: ref.folder.transcriptBackup, encoding: .utf8) == "previous")
}
