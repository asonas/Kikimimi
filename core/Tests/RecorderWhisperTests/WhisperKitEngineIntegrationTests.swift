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

// Gated: IR_INTEGRATION=1 mise run test --filter RecorderWhisperTests. Downloads openai_whisper-tiny (~75 MB), uses a
// 20 s Japanese fixture synthesized by `say -v Kyoko` with a known sentence at t = 8 s.
// Must establish: (1) segment times are file-relative (sentence start ~ 8 s +- 1.5 s) with chunkingStrategy .vad on the
// .incremental loading path; (2) cancelling the Task during transcribe throws .cancelled within 5 s and the model is
// unloaded; (3) kit.progress sampled during a track gives usable (Core clamps it monotone) values;
// (4) with the model folder missing, transcribe throws .modelNotInstalled and never downloads.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IR_INTEGRATION"] == "1")) func transcribesFixtureWithFileRelativeTimes() async throws {
    Issue.record("not implemented")
}
