import AVFoundation
import Foundation
import RecorderCore
import Testing
@testable import RecorderAudio

private let rate = 1000.0
private func chunk(_ time: Double, _ samples: [Float], sampleRate: Double = rate) -> AudioChunk {
    .init(hostSeconds: time, sampleRate: sampleRate, samples: samples)
}
private func zeros(_ count: Int = 1000) -> [Float] { .init(repeating: 0, count: count) }

private actor ScriptedSource: AudioSource {
    let script: [AudioChunk]
    let error: Bool
    let hold: Bool
    var stopped = false
    var continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation?
    init(_ script: [AudioChunk], error: Bool = false, hold: Bool = false) {
        self.script = script; self.error = error; self.hold = hold
    }
    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        let pair = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        continuation = pair.continuation
        if stopped { pair.continuation.finish(); return pair.stream }
        for chunk in script { pair.continuation.yield(chunk) }
        if error { pair.continuation.finish(throwing: CocoaError(.fileReadUnknown)) }
        else if !hold { pair.continuation.finish() }
        return pair.stream
    }
    func stop() async { stopped = true; continuation?.finish() }
}

private actor AnchorGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class CaptureEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CaptureEvent] = []
    func append(_ event: CaptureEvent) { lock.withLock { values.append(event) } }
    var events: [CaptureEvent] { lock.withLock { values } }
    var digital: [Bool] {
        events.compactMap { if case .digitalSilence(_, let active) = $0 { return active }; return nil }
    }
    var failures: [TrackFailure] {
        events.compactMap { if case .trackFailed(_, let failure) = $0 { return failure }; return nil }
    }
}

private func recorderFolder() throws -> SessionFolder {
    let folder = SessionFolder(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    return folder
}

private func recordedPCM(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
    var samples: [Float] = []
    while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
        guard buffer.frameLength > 0 else { Issue.record("unexpected EOF"); break }
        samples += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    return samples
}

@Test func trackRecorderAwaitsAnchorBeforeCreatingSpool() async throws {
    let folder = try recorderFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    let gate = AnchorGate(), events = CaptureEvents()
    let source = ScriptedSource([chunk(100, [0.5, -0.5])])
    let recorder = TrackRecorder(track: .me, source: source, folder: folder, willWriteFirstSample: { track, host in
        #expect(track == .me); #expect(host == 100)
        #expect(!FileManager.default.fileExists(atPath: folder.spool(.me).path))
        await gate.wait()
        #expect(!FileManager.default.fileExists(atPath: folder.spool(.me).path))
    }, emit: { events.append($0) })
    let run = Task { await recorder.run() }
    for _ in 0..<10000 { if await gate.entered { break }; await Task.yield() }
    #expect(await gate.entered)
    #expect(!FileManager.default.fileExists(atPath: folder.spool(.me).path))
    await gate.release(); await run.value
    #expect(try recordedPCM(folder.spool(.me)) == [0.5, -0.5])
    #expect(events.failures.isEmpty)
}

@Test func trackRecorderPlacesScriptedGapsAndDropsDuplicatedSamples() async throws {
    let folder = try recorderFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    let events = CaptureEvents()
    let source = ScriptedSource([
        chunk(100, [Float](repeating: 0.25, count: 1000)),
        chunk(102, [Float](repeating: 0.5, count: 1000)),
        chunk(102, [Float](repeating: 0.75, count: 1000)),
        chunk(103, [Float](repeating: -0.5, count: 1000)),
    ])
    let recorder = TrackRecorder(track: .remote, source: source, folder: folder,
                                 willWriteFirstSample: { _, _ in }, emit: { events.append($0) })
    await recorder.run()
    let diagnostics = await recorder.stop()
    #expect(diagnostics?.gapFillFrames == 1000)
    #expect(diagnostics?.gapCount == 1)
    #expect(diagnostics?.overlapDroppedFrames == 1000)
    let pcm = try recordedPCM(folder.spool(.remote))
    #expect(pcm == [Float](repeating: 0.25, count: 1000) + zeros() + [Float](repeating: 0.5, count: 1000) + [Float](repeating: -0.5, count: 1000))
    #expect(events.failures.isEmpty)
}

@Test func trackRecorderDigitalSilenceUsesOnlySelfSourceSamples() async throws {
    for track in Track.allCases {
        let folder = try recorderFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
        let events = CaptureEvents()
        let source = ScriptedSource([chunk(100, zeros()), chunk(101, zeros()), chunk(102, zeros()),
                                     chunk(103, zeros()), chunk(104, [0.01])])
        let recorder = TrackRecorder(track: track, source: source, folder: folder,
            willWriteFirstSample: { _, _ in }, emit: { events.append($0) })
        await recorder.run()
        #expect(events.digital == (track == .me ? [true, false] : []))
        #expect(events.failures.isEmpty)
    }
}

@Test func trackRecorderGapNeitherTriggersNorResetsDigitalSilence() async throws {
    let scripts: [([AudioChunk], [Bool])] = [
        ([chunk(100, zeros()), chunk(101, zeros()), chunk(107, zeros(500))], []),
        ([chunk(100, zeros()), chunk(101, zeros()), chunk(107, zeros(500)), chunk(107.5, zeros(500))], [true]),
        ([chunk(100, zeros(3000)), chunk(108, zeros(500))], [true]),
    ]
    for (script, expected) in scripts {
        let folder = try recorderFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
        let events = CaptureEvents()
        let recorder = TrackRecorder(track: .me, source: ScriptedSource(script), folder: folder,
            willWriteFirstSample: { _, _ in }, emit: { events.append($0) })
        await recorder.run()
        #expect(events.digital == expected)
        #expect((await recorder.stop())?.gapFillFrames == 5000)
    }
}

@Test func trackRecorderSourceErrorClosesSpoolBeforeFailureEvent() async throws {
    let folder = try recorderFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    let events = CaptureEvents()
    let recorder = TrackRecorder(track: .me, source: ScriptedSource([chunk(100, zeros())], error: true), folder: folder,
        willWriteFirstSample: { _, _ in }, emit: { event in
            if case .trackFailed = event {
                do { #expect(try recordedPCM(folder.spool(.me)).count == 1000) }
                catch { Issue.record("spool not readable at failure event: \(error)") }
            }
            events.append(event)
        })
    await recorder.run()
    #expect(events.failures.count == 1)
    #expect(events.failures.first?.code == .streamStopped)
    #expect(events.failures.first?.atSeconds == 1)
}

@Test func trackRecorderAnchorFailureCreatesNoSpoolAndOtherTrackContinues() async throws {
    let folder = try recorderFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    let localEvents = CaptureEvents(), remoteEvents = CaptureEvents()
    let local = TrackRecorder(track: .me, source: ScriptedSource([chunk(100, zeros())]), folder: folder,
        willWriteFirstSample: { _, _ in throw CocoaError(.fileWriteNoPermission) }, emit: { localEvents.append($0) })
    let remote = TrackRecorder(track: .remote, source: ScriptedSource([chunk(100, [0.5])]), folder: folder,
        willWriteFirstSample: { _, _ in }, emit: { remoteEvents.append($0) })
    async let first: Void = local.run()
    async let second: Void = remote.run()
    _ = await (first, second)
    #expect(!FileManager.default.fileExists(atPath: folder.spool(.me).path))
    #expect(localEvents.failures.count == 1)
    #expect(localEvents.failures.first?.code == .writeFailed)
    #expect(try recordedPCM(folder.spool(.remote)) == [0.5])
    #expect(remoteEvents.failures.isEmpty)
}

@Test func trackRecorderFormatChangeFailsWithoutAppendingNewRate() async throws {
    let folder = try recorderFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    let events = CaptureEvents()
    let recorder = TrackRecorder(track: .me, source: ScriptedSource([chunk(100, [0.5]), chunk(101, [0.25], sampleRate: 2000)]),
        folder: folder, willWriteFirstSample: { _, _ in }, emit: { events.append($0) })
    await recorder.run()
    #expect(events.failures.first?.code == .formatChanged)
    #expect(try recordedPCM(folder.spool(.me)) == [0.5])
}

@Test func trackRecorderEmitsLevelPeaksPerSourceSecondNotPadding() async throws {
    let folder = try recorderFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    let events = CaptureEvents()
    let recorder = TrackRecorder(track: .remote, source: ScriptedSource([
        chunk(100, [Float](repeating: 0.5, count: 500)), chunk(105.5, [Float](repeating: 0.25, count: 500)),
        chunk(106, zeros())]), folder: folder, willWriteFirstSample: { _, _ in }, emit: { events.append($0) })
    await recorder.run()
    let levels = events.events.compactMap { if case .level(_, let peak) = $0 { return peak }; return nil as Float? }
    #expect(levels.count == 2)
    #expect(abs((levels.first ?? 0) + 6.0206) < 0.001)
    #expect(levels.last == -120)
    let meter = events.events.compactMap { if case .meter(_, let peak) = $0 { return peak }; return nil as Float? }
    #expect(meter.count == 40) // 2 source seconds, excluding the five seconds of gap padding
    #expect(meter.prefix(10).allSatisfy { abs($0 + 6.0206) < 0.001 })
    #expect(meter.dropFirst(10).prefix(10).allSatisfy { abs($0 + 12.0412) < 0.001 })
    #expect(meter.suffix(20).allSatisfy { $0 == -120 })
    #expect(try recordedPCM(folder.spool(.remote)) == [Float](repeating: 0.5, count: 500)
            + zeros(5000) + [Float](repeating: 0.25, count: 500) + zeros())
}

@Test func trackRecorderEmptySourceDoesNotCreateSpool() async throws {
    let folder = try recorderFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    let events = CaptureEvents()
    let recorder = TrackRecorder(track: .me, source: ScriptedSource([chunk(100, [])]), folder: folder,
        willWriteFirstSample: { _, _ in Issue.record("no anchor for empty source") }, emit: { events.append($0) })
    await recorder.run()
    #expect(await recorder.stop() == nil)
    #expect(events.events.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: folder.spool(.me).path))
}

@Test func trackRecorderStopDrainsBufferedSourceAndClosesSpool() async throws {
    let folder = try recorderFolder(); defer { try? FileManager.default.removeItem(at: folder.url) }
    let events = CaptureEvents()
    let source = ScriptedSource((0..<10).map { chunk(100 + Double($0), zeros()) }, hold: true)
    let recorder = TrackRecorder(track: .remote, source: source, folder: folder,
        willWriteFirstSample: { _, _ in }, emit: { events.append($0) })
    let first = Task { await recorder.run() }
    for _ in 0..<10000 { if await source.continuation != nil { break }; await Task.yield() }
    #expect(await source.continuation != nil)
    let duplicate = Task { await recorder.run() }
    let diagnostics = await recorder.stop()
    await first.value; await duplicate.value
    #expect(diagnostics?.gapCount == 0)
    #expect(try recordedPCM(folder.spool(.remote)).count == 10_000)
    #expect(events.failures.isEmpty)
}
