import AVFoundation
import Foundation
import RecorderCore
import Testing
@testable import RecorderAudio

private actor BackendTestSource: AudioSource {
    let folder: SessionFolder
    let fail: Bool
    let failureAfterAudio: Bool
    var starts = 0
    var stops = 0
    var continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation?
    init(folder: SessionFolder, fail: Bool = false, failureAfterAudio: Bool = false) {
        self.folder = folder; self.fail = fail; self.failureAfterAudio = failureAfterAudio
    }
    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        starts += 1
        for track in Track.allCases { #expect(!FileManager.default.fileExists(atPath: folder.spool(track).path)) }
        if fail { throw AudioSourceFailure(code: .streamStopped, message: "Start failed") }
        let pair = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        continuation = pair.continuation
        pair.continuation.yield(.init(hostSeconds: 100, sampleRate: 48_000, samples: [Float](repeating: 0.25, count: 4800)))
        if failureAfterAudio { pair.continuation.finish(throwing: AudioSourceFailure(code: .targetAppQuit, message: "App quit")) }
        return pair.stream
    }
    func stop() async { stops += 1; continuation?.finish() }
}

private func backendFolder() throws -> SessionFolder {
    let folder = SessionFolder(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    return folder
}

private func backendPlan(_ folder: SessionFolder) -> CapturePlan {
    .init(folder: folder, mic: (.init(uid: "fake", name: "Fake", inputChannels: 1, isSystemDefault: false), 1),
          remote: .allSystemAudio, willWriteFirstSample: { _, _ in })
}

@Test func remoteCandidatesPutZoomChromeTeamsWebexFaceTimeFirstAndSystemLast() {
    let expected = ["us.zoom.xos", "com.google.Chrome", "com.microsoft.teams2", "com.cisco.webexmeetingsapp", "com.apple.FaceTime", "other.a", "other.b"]
    let names = ["Zoom", "Chrome", "Teams", "Webex", "FaceTime", "Alpha", "Beta"]
    let apps = zip(expected, names).reversed().map { RemoteSource.app(bundleID: $0.0, name: $0.1) }
    let sorted = TwoTrackCapture.orderedCandidates(apps + [apps[0], .allSystemAudio])
    #expect(sorted.compactMap { if case .app(let id, _) = $0 { return id }; return nil } == expected)
    #expect(sorted.last == .allSystemAudio)
    #expect(sorted.count == expected.count + 1)
    #expect(TwoTrackCapture.orderedCandidates([]) == [.allSystemAudio])
}

@Test func twoTrackCaptureStartsBothBeforeSpoolingAndDrainsOnImmediateStop() async throws {
    let folder = try backendFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    let mic = BackendTestSource(folder: folder), remote = BackendTestSource(folder: folder)
    let running = try await TwoTrackCapture().start(backendPlan(folder), mic: mic, remote: remote)
    let diagnostics = await running.stop()
    let repeated = await running.stop()
    #expect(diagnostics == repeated)
    for track in Track.allCases {
        #expect(try AVAudioFile(forReading: folder.spool(track)).length == 4800)
        #expect(diagnostics[track]?.gapCount == 0)
    }
    #expect(await mic.starts == 1)
    #expect(await remote.starts == 1)
    #expect(await mic.stops > 0)
    #expect(await remote.stops > 0)
    var failures = 0
    for await event in running.events { if case .trackFailed = event { failures += 1 } }
    #expect(failures == 0)
}

@Test func twoTrackCaptureRollsBackEitherSourceStartFailureWithoutSpool() async throws {
    for micFails in [true, false] {
        let folder = try backendFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
        let mic = BackendTestSource(folder: folder, fail: micFails)
        let remote = BackendTestSource(folder: folder, fail: !micFails)
        await #expect(throws: AudioSourceFailure.self) {
            try await TwoTrackCapture().start(backendPlan(folder), mic: mic, remote: remote)
        }
        #expect(await mic.stops == 1)
        #expect(await remote.stops == 1)
        for track in Track.allCases { #expect(!FileManager.default.fileExists(atPath: folder.spool(track).path)) }
    }
}

@Test func twoTrackCaptureForwardsTargetAppQuitWithoutLosingOtherTrack() async throws {
    let folder = try backendFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    let mic = BackendTestSource(folder: folder)
    let remote = BackendTestSource(folder: folder, failureAfterAudio: true)
    let running = try await TwoTrackCapture().start(backendPlan(folder), mic: mic, remote: remote)
    _ = await running.stop()
    var failures: [(Track, TrackFailure)] = []
    for await event in running.events {
        if case .trackFailed(let track, let failure) = event { failures.append((track, failure)) }
    }
    #expect(failures.count == 1)
    #expect(failures.first?.0 == .remote)
    #expect(failures.first?.1.code == .targetAppQuit)
    #expect(try AVAudioFile(forReading: folder.spool(.me)).length == 4800)
}
