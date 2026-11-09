import Foundation
import Testing
@testable import RecorderCore

private let recoveryStart = Date(timeIntervalSince1970: 1000)

private actor FakeRecoveryAudio: AudioFinalizer {
    var calls = 0
    var failures: Set<String> = []
    func fail(_ folder: SessionFolder) { failures.insert(folder.url.lastPathComponent) }
    func finalize(_ folder: SessionFolder, clockTolerance: Double) async throws -> FinalizedAudio {
        calls += 1
        if failures.contains(folder.url.lastPathComponent) { throw FinalizeError.encodeFailed("fake") }
        var tracks = PerTrack<TrackAudio>()
        for track in Track.allCases {
            let fm = FileManager.default
            if fm.fileExists(atPath: folder.audioPart(track).path) { try fm.removeItem(at: folder.audioPart(track)) }
            if fm.fileExists(atPath: folder.spool(track).path) {
                if !fm.fileExists(atPath: folder.audio(track).path) { try Data([1]).write(to: folder.audio(track)) }
                try fm.removeItem(at: folder.spool(track))
            }
            if fm.fileExists(atPath: folder.audio(track).path) {
                tracks[track] = .init(file: folder.audio(track).lastPathComponent, sampleRate: 48_000,
                                     frames: track == .me ? 144_000 : 96_000, peakDBFS: -6)
            }
        }
        return .init(tracks: tracks)
    }
}

private func recoverySetup() throws -> (URL, SessionStore, FakeRecoveryAudio) {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, SessionStore(root: root, now: { recoveryStart }), FakeRecoveryAudio())
}

private func recoverySession(_ store: SessionStore) async throws -> (SessionRef, CaptureLease) {
    let result = try await store.create(.init(company: "test", remote: .allSystemAudio),
        mic: .mic(deviceUID: "uid", deviceName: "Mic", channel: 1, deviceChannels: 1),
        remote: .allSystemAudio, app: .init(version: "1", build: "1", os: "test"))
    return (result.ref, result.lease)
}

@Test func launchRecoveryCrashPointTable() async throws {
    for scenario in ["before-capture", "during-capture", "stopped", "during-encode", "after-rename", "after-delete"] {
        let (root, store, audio) = try recoverySetup(); defer { try? FileManager.default.removeItem(at: root) }
        let (ref, lease) = try await recoverySession(store)
        if scenario != "before-capture" {
            try await store.update(ref) { $0.tracks.me?.firstSampleHostSeconds = 100 }
            if scenario != "after-delete" { try Data([1]).write(to: ref.folder.spool(.me)) }
            if scenario == "during-encode" { try Data([2]).write(to: ref.folder.audioPart(.me)) }
            if scenario == "after-rename" || scenario == "after-delete" {
                try Data([3]).write(to: ref.folder.audio(.me))
            }
            if scenario == "stopped" {
                try await store.update(ref) { $0.capture = .finished(endedAt: recoveryStart.addingTimeInterval(9), reason: .quit) }
            }
        }
        lease.release()
        let finalizer = SessionFinalizer(store: store, audio: audio)
        let recovered = try await LaunchRecovery.run(store: store, finalizer: finalizer)
        if scenario == "before-capture" {
            #expect(recovered.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: ref.folder.url.path))
        } else {
            #expect(recovered.map(\.id) == [ref.id])
            #expect(try await store.state(of: ref) == .readyToTranscribe)
            let meta = try await store.meta(of: ref)
            let reason: EndReason = scenario == "stopped" ? .quit : .recovered
            let end = recoveryStart.addingTimeInterval(scenario == "stopped" ? 9 : 3)
            #expect(meta.capture == .finished(endedAt: end, reason: reason))
            #expect(meta.tracks.remote?.failure?.code == .noAudioEver)
            #expect(try await store.segments(of: ref) == nil)
            #expect(!FileManager.default.fileExists(atPath: ref.folder.transcript.path))
            #expect(try await LaunchRecovery.run(store: store, finalizer: finalizer).isEmpty)
        }
    }
}

@Test func launchRecoveryNeverTouchesHeldLeaseEvenWithoutAudio() async throws {
    for withAudio in [false, true] {
        let (root, store, audio) = try recoverySetup(); defer { try? FileManager.default.removeItem(at: root) }
        let (ref, lease) = try await recoverySession(store)
        defer { lease.release() }
        if withAudio { try Data([1]).write(to: ref.folder.spool(.me)) }
        let bytes = try Data(contentsOf: ref.folder.meta)
        #expect(try await LaunchRecovery.run(store: store, finalizer: .init(store: store, audio: audio)).isEmpty)
        #expect(try Data(contentsOf: ref.folder.meta) == bytes)
        #expect(FileManager.default.fileExists(atPath: ref.folder.url.path))
        #expect(await audio.calls == 0)
        #expect(CaptureLease.isHeld(ref.folder.lock))
    }
}

@Test func sessionFinalizerRecoveredEndUsesTimelineAndClearsDiagnostics() async throws {
    let (root, store, audio) = try recoverySetup(); defer { try? FileManager.default.removeItem(at: root) }
    let (ref, lease) = try await recoverySession(store); defer { lease.release() }
    try await store.update(ref) {
        $0.tracks.remote?.firstSampleHostSeconds = 100
        $0.tracks.me?.firstSampleHostSeconds = 100.5
        $0.tracks.me?.diagnostics = .init(gapFillFrames: 1, gapCount: 1, overlapDroppedFrames: 0, maxAbsDriftSeconds: 0.1)
    }
    for track in Track.allCases { try Data([1]).write(to: ref.folder.spool(track)) }
    let finalizer = SessionFinalizer(store: store, audio: audio)
    try await finalizer.run(ref, reason: .recovered)
    let first = try await store.meta(of: ref)
    guard case let .finished(endedAt, reason) = first.capture else { Issue.record("expected finished"); return }
    let exactEnd = recoveryStart.addingTimeInterval(3.5)
    #expect(reason == .recovered)
    #expect(exactEnd.timeIntervalSince(endedAt) >= 0 && exactEnd.timeIntervalSince(endedAt) < 1)
    #expect(first.tracks.me?.diagnostics == nil)
    try await finalizer.run(ref, reason: .recovered)
    #expect(try await store.meta(of: ref) == first)
}

@Test func sessionFinalizerUsesLiveEndAndDiagnosticsAndPreservesFailure() async throws {
    let (root, store, audio) = try recoverySetup(); defer { try? FileManager.default.removeItem(at: root) }
    let (ref, lease) = try await recoverySession(store); defer { lease.release() }
    let failure = TrackFailure(code: .deviceLost, message: "unplugged")
    try await store.update(ref) { $0.tracks.remote?.failure = failure }
    try Data([1]).write(to: ref.folder.spool(.me))
    let diagnostics = ClockDiagnostics(gapFillFrames: 1, gapCount: 1, overlapDroppedFrames: 0, maxAbsDriftSeconds: 0.1)
    try await SessionFinalizer(store: store, audio: audio).run(ref, reason: .user,
        clockDiagnostics: .init(me: diagnostics), endedAt: recoveryStart.addingTimeInterval(10))
    let meta = try await store.meta(of: ref)
    #expect(meta.capture == .finished(endedAt: recoveryStart.addingTimeInterval(10), reason: .user))
    #expect(meta.tracks.me?.diagnostics == diagnostics)
    #expect(meta.tracks.remote?.failure == failure)
}

@Test func launchRecoverySkipsEncodeFailureAndContinues() async throws {
    let (root, store, audio) = try recoverySetup(); defer { try? FileManager.default.removeItem(at: root) }
    let (bad, badLease) = try await recoverySession(store)
    let (good, goodLease) = try await recoverySession(store)
    for ref in [bad, good] {
        try await store.update(ref) { $0.tracks.me?.firstSampleHostSeconds = 100 }
        try Data([1]).write(to: ref.folder.spool(.me))
    }
    badLease.release(); goodLease.release()
    await audio.fail(bad.folder)
    let before = try Data(contentsOf: bad.folder.meta)
    let recovered = try await LaunchRecovery.run(store: store, finalizer: .init(store: store, audio: audio))
    #expect(recovered.map(\.id) == [good.id])
    #expect(try Data(contentsOf: bad.folder.meta) == before)
    #expect(try await store.state(of: bad) == .needsFinalize)
    #expect(!CaptureLease.isHeld(bad.folder.lock))
}

@Test func launchRecoveryLeavesTranscribedAndNewerSchemaUntouched() async throws {
    let (root, store, audio) = try recoverySetup(); defer { try? FileManager.default.removeItem(at: root) }
    let (ref, lease) = try await recoverySession(store)
    try await store.update(ref) { $0.capture = .finished(endedAt: recoveryStart, reason: .user) }
    try Data([1]).write(to: ref.folder.audio(.me))
    let segments = SegmentsFile(schemaVersion: 1, createdAt: recoveryStart,
        transcriber: .init(engine: "fake", engineVersion: nil, model: "fake", language: "ja", chunking: "none"),
        tracks: .init(me: .transcribed), segments: [])
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(segments).write(to: ref.folder.segments)
    lease.release()
    #expect(try await LaunchRecovery.run(store: store, finalizer: .init(store: store, audio: audio)).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: ref.folder.transcript.path))
    let future = Data(#"{"schemaVersion":2}"#.utf8); try future.write(to: ref.folder.meta)
    #expect(try await LaunchRecovery.run(store: store, finalizer: .init(store: store, audio: audio)).isEmpty)
    #expect(try Data(contentsOf: ref.folder.meta) == future)
    #expect(await audio.calls == 0)
}
