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
