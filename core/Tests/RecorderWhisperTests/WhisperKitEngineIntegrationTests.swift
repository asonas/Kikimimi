import Foundation
import RecorderCore
import Testing
@testable import RecorderWhisper

// Not gated: the adapter's own policy, no model needed.
@Test func tracksRunRemoteFirstThenSelfAndOnlyThoseRequested() {
    let a = URL(fileURLWithPath: "/tmp/a.m4a"), b = URL(fileURLWithPath: "/tmp/b.m4a")
    #expect(WhisperKitEngine.trackOrder(PerTrack(me: a, remote: b)) == [.remote, .me])
    #expect(WhisperKitEngine.trackOrder(PerTrack(me: a)) == [.me])
    #expect(WhisperKitEngine.trackOrder(PerTrack<URL>()).isEmpty)
}

// Explicit opt-in, preinstalled tiny only. No test calls install/download, including when the model is missing.
// IR_MODEL_BASE points at the Models directory containing installed.json, not the downloaded snapshot itself.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["IR_INTEGRATION"] == "1"))
struct WhisperKitIntegrationTests {
    private func installedEngine() async throws -> WhisperKitEngine {
        let base = ProcessInfo.processInfo.environment["IR_MODEL_BASE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Kikimimi/Models")
        let engine = LiveWhisper.engine(base: base, variant: "openai_whisper-tiny")
        guard await engine.status() == .ready else { throw TranscriberError.modelNotInstalled }
        return engine
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "m4a", subdirectory: "Fixtures"))
    }

    private func assertSpeech(_ segments: [EngineSegmentDTO], near seconds: Float) {
        let speech = segments.filter { $0.text.contains("面接") || $0.text.contains("録音") }
        #expect(speech.contains { abs($0.start - seconds) <= 1.5 }, "Expected Kyoko speech near \(seconds)s; got \(segments)")
    }

    @Test func transcribesFixtureWithFileRelativeTimes() async throws {
        let engine = try await installedEngine()
        let result = try await engine.transcribe(.init(audio: .init(remote: try fixture("kyoko-20s")), language: "ja")) { _, _ in }
        assertSpeech(try #require(result[.remote]), near: 8)
        #expect(result[.me] == nil)
        #expect(await !engine.isModelLoaded)
    }

    @Test func transcribesLongFixtureAcrossVADWindowsAndSamplesProgress() async throws {
        let engine = try await installedEngine(), events = IntegrationProgress()
        let result = try await engine.transcribe(.init(audio: .init(me: try fixture("kyoko-20s"), remote: try fixture("kyoko-80s")), language: "ja"), progress: events.append)
        let remote = try #require(result[.remote])
        assertSpeech(remote, near: 8); assertSpeech(remote, near: 68)
        assertSpeech(try #require(result[.me]), near: 8)
        for track in [Track.remote, .me] {
            let samples = events.values.filter { $0.track == track }.map(\.fraction)
            #expect(samples.first == 0); #expect(samples.last == 1)
            #expect(samples.allSatisfy { $0.isFinite && (0...1).contains($0) })
            #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
            print("WHISPER PROGRESS \(track): \(samples)")
        }
        #expect(events.values.filter { $0.track == .remote }.count > 2, "Expected a 2 Hz in-track progress sample")
        #expect(await !engine.isModelLoaded)
    }

    @Test func cancellationReturnsWithinFiveSecondsAndUnloadsModel() async throws {
        let engine = try await installedEngine(), file = try fixture("kyoko-80s")
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            return try await engine.transcribe(.init(audio: .init(me: file, remote: file), language: "ja")) { track, fraction in
                if track == .remote { continuation.yield(fraction) }
            }
        }
        defer { task.cancel() }
        var count = 0
        var last = 1.0
        for await fraction in stream {
            count += 1
            last = fraction
            if count == 2 { break } // begin + first 2 Hz sample: cancel inside a track, after model load
        }
        #expect(count == 2, "Fixture finished before cancellation could be exercised")
        #expect(last < 1, "Cancellation must be exercised before whole-track completion")
        #expect(await engine.isModelLoaded)
        let clock = ContinuousClock(), started = clock.now
        task.cancel()
        await #expect(throws: TranscriberError.cancelled) { try await task.value }
        let latency = started.duration(to: clock.now)
        print("WHISPER CANCEL LATENCY: \(latency)")
        #expect(latency < .seconds(5))
        #expect(await !engine.isModelLoaded)
    }
}

private struct IntegrationProgressEvent: Sendable {
    let track: Track
    let fraction: Double
}

private final class IntegrationProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [IntegrationProgressEvent] = []
    func append(_ track: Track, _ fraction: Double) { lock.withLock { events.append(.init(track: track, fraction: fraction)) } }
    var values: [IntegrationProgressEvent] { lock.withLock { events } }
}
