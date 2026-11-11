import Foundation
import Testing
@testable import RecorderCore

private let controllerNow = Date(timeIntervalSince1970: 2000)
private let selectedMic = InputDeviceInfo(uid: "rubix", name: "Rubix44", inputChannels: 4, isSystemDefault: false)
private let preference = MicPreference(deviceUID: "rubix", deviceName: "Rubix44", channel: 1)
private let controllerDraft = SessionDraft(company: " Acme ", remote: .app(bundleID: "call.app", name: "old name"))
private let ready = Readiness(screen: .ready, mic: .authorized, micDevice: .use(device: selectedMic, channel: 1), model: .notInstalled)

private struct FakeControllerDevices: InputDeviceCatalog {
    var devices = [selectedMic]
    func inputDevices() throws -> [InputDeviceInfo] { devices }
}

private actor FakeRunning: RunningCapture {
    nonisolated let events: AsyncStream<CaptureEvent>
    nonisolated let continuation: AsyncStream<CaptureEvent>.Continuation
    var stops = 0
    init() {
        let pair = AsyncStream<CaptureEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    func stop() async -> PerTrack<ClockDiagnostics> {
        stops += 1
        continuation.finish()
        return .init(me: .init(gapFillFrames: 1, gapCount: 1, overlapDroppedFrames: 0, maxAbsDriftSeconds: 0.1))
    }
}

private actor FakeControllerBackend: CaptureBackend {
    nonisolated let capture = FakeRunning()
    var plan: CapturePlan?
    var failStart = false
    var delayStart = false
    var gate: CheckedContinuation<Void, Never>?
    var candidates: [RemoteSource] = [.app(bundleID: "call.app", name: "Actual Call")]
    func configure(fail: Bool = false, delay: Bool = false, missingApp: Bool = false) {
        failStart = fail; delayStart = delay
        if missingApp { candidates = [] }
    }
    func resume() { gate?.resume(); gate = nil }
    func runningRemoteCandidates() async throws -> [RemoteSource] { candidates }
    func start(_ plan: CapturePlan) async throws -> any RunningCapture {
        self.plan = plan
        if delayStart { await withCheckedContinuation { gate = $0 } }
        if failStart { throw CocoaError(.fileWriteUnknown) }
        for track in Track.allCases {
            try await plan.willWriteFirstSample(track, track == .me ? 100.5 : 100)
            try Data([1]).write(to: plan.folder.spool(track))
        }
        return capture
    }
}

private actor FakeControllerAudio: AudioFinalizer {
    var calls = 0
    var shouldFail = false
    var delay = false
    var gate: CheckedContinuation<Void, Never>?
    func setFailure() { shouldFail = true }
    func setDelay() { delay = true }
    func resume() { gate?.resume(); gate = nil }
    func finalize(_ folder: SessionFolder, clockTolerance: Double) async throws -> FinalizedAudio {
        calls += 1
        if delay { await withCheckedContinuation { gate = $0 } }
        if shouldFail { throw FinalizeError.encodeFailed("fake") }
        var tracks = PerTrack<TrackAudio>()
        for track in Track.allCases {
            try Data([2]).write(to: folder.audio(track))
            if FileManager.default.fileExists(atPath: folder.spool(track).path) {
                try FileManager.default.removeItem(at: folder.spool(track))
            }
            tracks[track] = .init(file: folder.audio(track).lastPathComponent, sampleRate: 48_000, frames: 48_000, peakDBFS: -6)
        }
        return .init(tracks: tracks)
    }
}

@MainActor private final class ControllerRig {
    let root: URL
    let store: SessionStore
    let backend = FakeControllerBackend()
    let audio = FakeControllerAudio()
    var finalized: [SessionRef] = []
    var phases: [RecordingPhase] = []
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SessionStore(root: root, now: { controllerNow })
    }
    func controller(readiness: Readiness = ready, mic: MicPreference? = preference,
                    devices: [InputDeviceInfo] = [selectedMic], free: Int64 = 5_000_000_000) -> RecordingController {
        var hooks = RecordingController.Hooks()
        hooks.phaseChanged = { [weak self] in self?.phases.append($0) }
        hooks.sessionFinalized = { [weak self] in self?.finalized.append($0) }
        return RecordingController(.init(store: store, backend: backend, devices: FakeControllerDevices(devices: devices),
            finalizer: .init(store: store, audio: audio), app: .init(version: "1", build: "1", os: "test"),
            now: { controllerNow.addingTimeInterval(10) }, availableDiskBytes: { _ in free }),
            readiness: { readiness }, mic: { mic }, hooks: hooks)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor private func waitUntil(_ predicate: @MainActor () async -> Bool) async {
    for _ in 0..<10000 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("condition did not become true")
}

@Test @MainActor func controllerHappyPathWritesAnchorsAndEnqueuesOnlyAfterFinalize() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let controller = rig.controller()
    try await controller.start(controllerDraft)
    let listing = try #require(try await rig.store.list().first)
    let ref = listing.ref
    #expect(listing.state == .capturing)
    #expect(rig.finalized.isEmpty)
    let initial = try await rig.store.meta(of: ref)
    #expect(initial.company == "Acme")
    #expect(initial.tracks.me?.firstSampleHostSeconds == 100.5)
    #expect(initial.tracks.remote?.source == .app(bundleID: "call.app", name: "Actual Call"))
    #expect(await rig.backend.plan?.remote == .app(bundleID: "call.app", name: "Actual Call"))
    await controller.stop()
    #expect(controller.phase == .idle)
    #expect(controller.levels == nil)
    #expect(rig.finalized.map(\.id) == [ref.id])
    #expect(await rig.audio.calls == 1)
    #expect(!CaptureLease.isHeld(ref.folder.lock))
    #expect(try await rig.store.meta(of: ref).capture == .finished(endedAt: controllerNow.addingTimeInterval(10), reason: .user))
    #expect(try await rig.store.meta(of: ref).tracks.me?.diagnostics?.gapCount == 1)
}

@Test @MainActor func controllerPreflightErrorsCreateNoFolders() async throws {
    for scenario in ["notReady", "missing", "channel", "app", "disk", "empty", "notChosen"] {
        let rig = try ControllerRig(); defer { rig.cleanup() }
        var readiness = ready
        var mic: MicPreference? = preference
        var devices = [selectedMic]
        var free: Int64 = 5_000_000_000
        var draft = controllerDraft
        let expected: StartError
        switch scenario {
        case "notReady": readiness.mic = .denied; expected = .notReady([.microphonePermission(.denied)])
        case "missing": devices = []; expected = .micMissing(preference)
        case "channel": mic?.channel = 5; expected = .micChannelOutOfRange(device: "Rubix44", requested: 5, available: 4)
        case "app": await rig.backend.configure(missingApp: true); expected = .remoteAppNotRunning(name: "old name")
        case "disk": free = 4_000_000_000; expected = .insufficientDisk(availableGB: 4)
        case "empty": draft.company = " \n "; expected = .companyEmpty
        default: mic = nil; expected = .notReady([.micNotChosen])
        }
        let controller = rig.controller(readiness: readiness, mic: mic, devices: devices, free: free)
        await #expect(throws: expected) { try await controller.start(draft) }
        #expect(controller.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: rig.root.path))
        #expect(await rig.backend.plan == nil)
    }
}

@Test @MainActor func controllerBackendFailureDiscardsEmptySessionAndReturnsIdle() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    await rig.backend.configure(fail: true)
    let controller = rig.controller()
    do { try await controller.start(controllerDraft); Issue.record("expected failure") }
    catch { guard case .captureFailed = error else { Issue.record("wrong error"); return } }
    #expect(controller.phase == .idle)
    #expect(try await rig.store.list().isEmpty)
    let plan = try #require(await rig.backend.plan)
    #expect(!FileManager.default.fileExists(atPath: plan.folder.url.path))
}

@Test @MainActor func controllerPersistsTrackFailureAndDigitalSilenceThroughMonitor() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let controller = rig.controller()
    try await controller.start(controllerDraft)
    let ref = try #require(try await rig.store.list().first?.ref)
    rig.backend.capture.continuation.yield(.level(.me, peakDBFS: -20))
    await waitUntil { controller.levels?.me == -20 }
    rig.backend.capture.continuation.yield(.digitalSilence(.me, active: true))
    await waitUntil {
        if case .recording(let r) = controller.phase { return r.health.me == .digitallySilent }; return false
    }
    rig.backend.capture.continuation.yield(.digitalSilence(.me, active: false))
    await waitUntil {
        if case .recording(let r) = controller.phase { return r.health.me == .live }; return false
    }
    let failure = TrackFailure(code: .deviceLost, message: "unplugged")
    rig.backend.capture.continuation.yield(.trackFailed(.me, failure))
    await waitUntil {
        if case .recording(let r) = controller.phase { return r.health.me == .failed(failure) }; return false
    }
    #expect(try await rig.store.meta(of: ref).tracks.me?.failure == failure)
    rig.backend.capture.continuation.yield(.digitalSilence(.me, active: true))
    rig.backend.capture.continuation.yield(.level(.remote, peakDBFS: -10))
    await waitUntil { controller.levels?.remote == -10 }
    if case .recording(let r) = controller.phase { #expect(r.health.me == .failed(failure)) }
    else { Issue.record("one failed track must keep recording") }
    await controller.stop()
}

@Test @MainActor func controllerDisplayPeaksDoNotFeedHealthAndClearOnStop() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let controller = rig.controller()
    try await controller.start(controllerDraft)
    for _ in 0..<1000 { rig.backend.capture.continuation.yield(.meter(.me, peakDBFS: -15)) }
    // A following health event is a barrier through the ordered capture stream.
    rig.backend.capture.continuation.yield(.level(.remote, peakDBFS: -10))
    await waitUntil { controller.levels?.remote == -10 }
    try await Task.sleep(for: .milliseconds(120))
    #expect(controller.meterLevels?.me?.dbFS == -15)
    #expect(controller.meterLevels?.me?.at != nil)
    #expect(controller.levels?.me == -120)
    if case .recording(let recording) = controller.phase {
        #expect(recording.health.me == .waitingForAudio)
        #expect(recording.health.remote == .live)
    } else { Issue.record("display events changed the capture phase") }
    await controller.stop()
    #expect(controller.meterLevels == nil)
    #expect(controller.levels == nil)
}

@Test @MainActor func controllerBothTrackFailuresStopWithCaptureLost() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let controller = rig.controller()
    try await controller.start(controllerDraft)
    let ref = try #require(try await rig.store.list().first?.ref)
    let failure = TrackFailure(code: .streamStopped, message: "stopped")
    for track in Track.allCases { rig.backend.capture.continuation.yield(.trackFailed(track, failure)) }
    await waitUntil { controller.phase == .idle }
    #expect(try await rig.store.meta(of: ref).capture == .finished(endedAt: controllerNow.addingTimeInterval(10), reason: .captureLost))
    #expect(await rig.backend.capture.stops == 1)
    #expect(rig.finalized.count == 1)
}

@Test @MainActor func controllerRejectsDoubleStartWhilePreparingAndRecording() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    await rig.backend.configure(delay: true)
    let controller = rig.controller()
    let start = Task { try await controller.start(controllerDraft) }
    await waitUntil { await rig.backend.gate != nil }
    await #expect(throws: StartError.alreadyActive) { try await controller.start(controllerDraft) }
    await rig.backend.resume()
    try await start.value
    await #expect(throws: StartError.alreadyActive) { try await controller.start(controllerDraft) }
    await controller.stop()
}

@Test @MainActor func controllerQuitDuringPreparationWaitsAndSkipsFinalize() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    await rig.backend.configure(delay: true)
    let controller = rig.controller()
    let start = Task { try await controller.start(controllerDraft) }
    await waitUntil { await rig.backend.gate != nil }
    let quit = Task { await controller.stopForQuit() }
    await Task.yield()
    await rig.backend.resume()
    try await start.value
    await quit.value
    #expect(controller.phase == .idle)
    #expect(await rig.audio.calls == 0)
    #expect(rig.finalized.isEmpty)
    let listing = try #require(try await rig.store.list().first)
    #expect(listing.state == .needsFinalize)
    #expect(try await rig.store.meta(of: listing.ref).capture == .finished(endedAt: controllerNow.addingTimeInterval(10), reason: .quit))
    #expect(!CaptureLease.isHeld(listing.ref.folder.lock))
    await controller.stopForQuit()
    #expect(await rig.backend.capture.stops == 1)
}

@Test @MainActor func controllerFinalizeFailureKeepsSpoolAndDoesNotEnqueue() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    await rig.audio.setFailure()
    let controller = rig.controller()
    try await controller.start(controllerDraft)
    await controller.stop()
    #expect(controller.phase == .idle)
    #expect(rig.finalized.isEmpty)
    let listing = try #require(try await rig.store.list().first)
    #expect(listing.state == .needsFinalize)
    #expect(!CaptureLease.isHeld(listing.ref.folder.lock))
}

@Test @MainActor func controllerWriteAheadHookPropagatesStorageFailure() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let controller = rig.controller()
    try await controller.start(controllerDraft)
    let plan = try #require(await rig.backend.plan)
    let bytes = try Data(contentsOf: plan.folder.meta)
    try Data(#"{"schemaVersion":2}"#.utf8).write(to: plan.folder.meta)
    await #expect(throws: SessionMetaError.self) { try await plan.willWriteFirstSample(.me, 999) }
    try bytes.write(to: plan.folder.meta)
    await controller.stopForQuit()
}

@Test @MainActor func controllerConcurrentStopsAndQuitAwaitSingleFinalize() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    await rig.audio.setDelay()
    let controller = rig.controller()
    try await controller.start(controllerDraft)
    let stop = Task { await controller.stop() }
    await waitUntil { await rig.audio.gate != nil }
    let duplicate = Task { await controller.stop() }
    let quit = Task { await controller.stopForQuit() }
    await Task.yield()
    #expect(rig.finalized.isEmpty)
    await rig.audio.resume()
    await stop.value; await duplicate.value; await quit.value
    #expect(controller.phase == .idle)
    #expect(await rig.audio.calls == 1)
    #expect(await rig.backend.capture.stops == 1)
    #expect(rig.finalized.count == 1)
}

@Test @MainActor func controllerQuitAfterFailedPreparationCompletes() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    await rig.backend.configure(fail: true, delay: true)
    let controller = rig.controller()
    let start = Task { try await controller.start(controllerDraft) }
    await waitUntil { await rig.backend.gate != nil }
    let quit = Task { await controller.stopForQuit() }
    await Task.yield()
    await rig.backend.resume()
    do { try await start.value; Issue.record("expected failure") } catch {}
    await quit.value
    #expect(controller.phase == .idle)
    #expect(try await rig.store.list().isEmpty)
    #expect(await rig.audio.calls == 0)
}

@Test @MainActor func terminationWaitsForQuitAndNextLaunchRecoversWithoutAutoTranscription() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let controller = rig.controller()
    try await controller.start(controllerDraft)
    let coordinator = TerminationCoordinator()
    var replies = 0
    coordinator.request(stop: { await controller.stopForQuit() }, sleep: { _ in throw CancellationError() }, reply: {
        #expect(controller.phase == .idle)
        replies += 1
    })
    await waitUntil { replies == 1 }
    #expect(await rig.audio.calls == 0)
    #expect(rig.finalized.isEmpty)
    let listing = try #require(try await rig.store.list().first)
    #expect(listing.state == .needsFinalize)
    #expect(!CaptureLease.isHeld(listing.ref.folder.lock))
    #expect(try await rig.store.meta(of: listing.ref).capture == .finished(endedAt: controllerNow.addingTimeInterval(10), reason: .quit))
    let recovered = try await LaunchRecovery.run(store: rig.store, finalizer: .init(store: rig.store, audio: rig.audio))
    #expect(recovered.map(\.id) == [listing.id])
    #expect(try await rig.store.state(of: listing.ref) == .readyToTranscribe)
    #expect(try await rig.store.segments(of: listing.ref) == nil)
    #expect(rig.finalized.isEmpty)
}

private actor PipelineModels: ModelProvider {
    let ready: Bool
    init(ready: Bool = true) { self.ready = ready }
    func status() async -> ModelStatus { ready ? .ready : .notInstalled }
    func install(progress: @escaping @Sendable (ModelStatus) -> Void) async throws {
        Issue.record("E2E must not install a model")
    }
}

private actor PipelineTranscriber: Transcriber {
    var requests: [TranscribeRequest] = []
    var text = "最初の文字起こし"
    var failure = false
    func configure(text: String, failure: Bool = false) { self.text = text; self.failure = failure }
    nonisolated func identity(language: String) -> TranscriberIdentity {
        .init(engine: "fake", engineVersion: "1", model: "fake", language: language, chunking: "vad")
    }
    func transcribe(_ request: TranscribeRequest, progress: @escaping @Sendable (Track, Double) -> Void) async throws -> PerTrack<[EngineSegmentDTO]> {
        requests.append(request)
        if failure { throw TranscriberError.engine("scripted E2E failure") }
        var output = PerTrack<[EngineSegmentDTO]>()
        for (track, _) in request.audio.present {
            progress(track, 0); progress(track, 1)
            output[track] = [.init(start: 0, end: 0.5, text: text, avgLogprob: -0.1, noSpeechProb: 0, compressionRatio: 1)]
        }
        return output
    }
}

@MainActor private func pipelineController(_ rig: ControllerRig, _ service: TranscriptionService) -> RecordingController {
    var hooks = RecordingController.Hooks.transcribing(with: service)
    let enqueue = hooks.sessionFinalized
    hooks.sessionFinalized = { ref in
        let held = CaptureLease.isHeld(ref.folder.lock)
        #expect(!held, "Release the capture lease before enqueue")
        enqueue(ref)
    }
    return RecordingController(.init(store: rig.store, backend: rig.backend, devices: FakeControllerDevices(),
        finalizer: .init(store: rig.store, audio: rig.audio), app: .init(version: "1", build: "1", os: "test"),
        now: { controllerNow.addingTimeInterval(10) }, availableDiskBytes: { _ in 5_000_000_000 }),
        readiness: { ready }, mic: { preference }, hooks: hooks)
}

@Test @MainActor func pipelineStopFinalizesReleasesLeaseThenEnqueuesAndWritesTranscript() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let engine = PipelineTranscriber()
    let service = TranscriptionService(store: rig.store, transcriber: engine, models: PipelineModels(), language: { "ja" })
    let controller = pipelineController(rig, service)
    await rig.audio.setDelay()
    try await controller.start(controllerDraft)
    let ref = try #require(try await rig.store.list().first?.ref)
    let stop = Task { await controller.stop() }
    await waitUntil { await rig.audio.gate != nil }
    #expect(CaptureLease.isHeld(ref.folder.lock))
    #expect(service.jobs.isEmpty); #expect(await engine.requests.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: ref.folder.transcript.path))
    await rig.audio.resume(); await stop.value
    await waitUntil { service.jobs.first?.state == .done }
    #expect(controller.phase == .idle)
    #expect(await engine.requests.count == 1)
    let request = try #require(await engine.requests.first)
    #expect(request.audio.me?.resolvingSymlinksInPath().path == ref.folder.audio(.me).resolvingSymlinksInPath().path)
    #expect(request.audio.remote?.resolvingSymlinksInPath().path == ref.folder.audio(.remote).resolvingSymlinksInPath().path)
    let segments = try #require(try await rig.store.segments(of: ref))
    #expect(segments.segments.map(\.start) == [0, 0.5])
    #expect(try String(contentsOf: ref.folder.transcript, encoding: .utf8).contains("最初の文字起こし"))
    #expect(try await rig.store.state(of: ref) == .transcribed)
}

@Test @MainActor func pipelineRetranscribeReplacesAndBacksUpOnlyAfterSuccess() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let engine = PipelineTranscriber()
    let service = TranscriptionService(store: rig.store, transcriber: engine, models: PipelineModels(), language: { "ja" })
    let controller = pipelineController(rig, service)
    try await controller.start(controllerDraft); await controller.stop()
    await waitUntil { service.jobs.first?.state == .done }
    let ref = try #require(try await rig.store.list().first?.ref)
    let previous = try Data(contentsOf: ref.folder.transcript)
    let audio = try Data(contentsOf: ref.folder.audio(.me))
    await engine.configure(text: "新しい文字起こし")
    service.enqueue(ref); service.enqueue(ref)
    await waitUntil { service.jobs.first?.state == .done }
    #expect(await engine.requests.count == 2)
    #expect(try Data(contentsOf: ref.folder.transcriptBackup) == previous)
    let current = try Data(contentsOf: ref.folder.transcript), segments = try Data(contentsOf: ref.folder.segments)
    #expect(String(decoding: current, as: UTF8.self).contains("新しい文字起こし"))
    #expect(try Data(contentsOf: ref.folder.audio(.me)) == audio)
    await engine.configure(text: "失敗結果", failure: true)
    service.enqueue(ref)
    await waitUntil { if case .failed = service.jobs.first?.state { true } else { false } }
    #expect(try Data(contentsOf: ref.folder.transcript) == current)
    #expect(try Data(contentsOf: ref.folder.segments) == segments)
    #expect(try Data(contentsOf: ref.folder.transcriptBackup) == previous)
}

@Test @MainActor func pipelineQuitAndRecoveryNeverAutoEnqueueButExplicitTranscribeWorks() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let engine = PipelineTranscriber()
    let service = TranscriptionService(store: rig.store, transcriber: engine, models: PipelineModels(), language: { "ja" })
    let controller = pipelineController(rig, service)
    try await controller.start(controllerDraft); await controller.stopForQuit()
    #expect(service.jobs.isEmpty); #expect(await rig.audio.calls == 0)
    let recovered = try await LaunchRecovery.run(store: rig.store, finalizer: .init(store: rig.store, audio: rig.audio))
    let ref = try #require(recovered.first)
    #expect(service.jobs.isEmpty); #expect(await engine.requests.isEmpty)
    #expect(try await rig.store.state(of: ref) == .readyToTranscribe)
    // Both the recent-session button and headless transcribe resolve the ref from this listing, then enqueue.
    let listed = try #require(try await rig.store.list().first { $0.id == ref.id })
    service.enqueue(listed.ref)
    await waitUntil { service.jobs.first?.state == .done }
    #expect(try String(contentsOf: ref.folder.transcript, encoding: .utf8).contains("最初の文字起こし"))
}

@Test @MainActor func pipelineFinalizeFailureNeverEnqueuesOrWritesTranscript() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let engine = PipelineTranscriber()
    let service = TranscriptionService(store: rig.store, transcriber: engine, models: PipelineModels(), language: { "ja" })
    let controller = pipelineController(rig, service)
    await rig.audio.setFailure()
    try await controller.start(controllerDraft); await controller.stop()
    #expect(service.jobs.isEmpty); #expect(await engine.requests.isEmpty)
    let ref = try #require(try await rig.store.list().first?.ref)
    #expect(try await rig.store.state(of: ref) == .needsFinalize)
    #expect(!FileManager.default.fileExists(atPath: ref.folder.transcript.path))
}

@Test @MainActor func pipelineWithoutInstalledModelQueuesWithoutTranscribingOrInstalling() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let engine = PipelineTranscriber()
    let service = TranscriptionService(store: rig.store, transcriber: engine, models: PipelineModels(ready: false), language: { "ja" })
    let controller = pipelineController(rig, service)
    try await controller.start(controllerDraft); await controller.stop()
    await waitUntil { service.jobs.first?.state == .waiting(.modelNotReady) }
    #expect(await engine.requests.isEmpty)
    let ref = try #require(try await rig.store.list().first?.ref)
    #expect(try await rig.store.state(of: ref) == .readyToTranscribe)
    #expect(!FileManager.default.fileExists(atPath: ref.folder.transcript.path))
}

@Test @MainActor func pipelinePhaseHookHoldsQueuedWorkUntilCaptureAndFinalizeFinish() async throws {
    let rig = try ControllerRig(); defer { rig.cleanup() }
    let earlier = rig.controller()
    try await earlier.start(controllerDraft); await earlier.stop()
    let previous = try #require(try await rig.store.list().first?.ref)
    let engine = PipelineTranscriber()
    let service = TranscriptionService(store: rig.store, transcriber: engine, models: PipelineModels(), language: { "ja" })
    let controller = pipelineController(rig, service)
    try await controller.start(controllerDraft)
    service.enqueue(previous)
    await waitUntil { service.jobs.first?.state == .waiting(.recordingInProgress) }
    #expect(await engine.requests.isEmpty)
    await rig.audio.setDelay()
    let stop = Task { await controller.stop() }
    await waitUntil { await rig.audio.gate != nil }
    #expect(service.jobs.first?.state == .waiting(.recordingInProgress))
    #expect(await engine.requests.isEmpty)
    await rig.audio.resume(); await stop.value
    await waitUntil { service.jobs.count == 2 && service.jobs.allSatisfy { $0.state == .done } }
    #expect(service.jobs.first?.id == previous.id)
    #expect(await engine.requests.count == 2)
}
