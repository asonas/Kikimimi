import Foundation
import Testing
@testable import RecorderCore

// These tests run against the sketch's *implemented* pure pieces (reducer, clock, meta Codable).
// They double as the executable spec for the coding agent: the first commits must keep them green.

private let draft = SessionDraft(company: "Acme", remote: .allSystemAudio)
private let ref = SessionRef(id: UUID(), folder: SessionFolder(url: URL(fileURLWithPath: "/tmp/x")))
private let t0 = Date(timeIntervalSince1970: 1_000)

@Test func happyPathTransitions() {
    var phase = RecordingPhase.idle
    var tr = phase.applying(.startRequested(draft)); #expect(tr.effects == [.prepare(draft)]); phase = tr.phase
    tr = phase.applying(.prepared(ref, startedAt: t0)); phase = tr.phase
    guard case .recording = phase else { Issue.record("expected recording"); return }
    tr = phase.applying(.stopRequested(.user)); #expect(tr.effects == [.stopCapture(reason: .user)]); phase = tr.phase
    tr = phase.applying(.captureStopped); #expect(tr.effects == [.finalize(ref, reason: .user)]); phase = tr.phase
    tr = phase.applying(.finalizeSucceeded); #expect(tr.effects == [.enqueueTranscription(ref)]); #expect(tr.phase == .idle)
}

@Test func startWhileRecordingIsIllegalAndStateIsKept() {
    let rec = RecordingPhase.recording(.init(ref: ref, startedAt: t0, health: .init(both: .live)))
    let tr = rec.applying(.startRequested(draft))
    #expect(tr.kind == .illegal); #expect(tr.phase == rec); #expect(tr.effects.isEmpty)
}

@Test func bothTracksFailingStopsTheCapture() {
    let rec = RecordingPhase.recording(.init(ref: ref, startedAt: t0, health: .init(both: .live)))
    let f = TrackFailure(code: .deviceLost, message: "unplugged")
    let one = rec.applying(.trackHealthChanged(.me, .failed(f)))
    #expect(one.kind == .moved); #expect(one.effects.isEmpty)
    let two = one.phase.applying(.trackHealthChanged(.remote, .failed(.init(code: .targetAppQuit, message: "quit"))))
    #expect(two.effects == [.stopCapture(reason: .captureLost)])
    if case .stopping(let s) = two.phase { #expect(s.reason == .captureLost) } else { Issue.record("expected stopping") }
}

@Test func quitDefersFinalize() {
    let stopping = RecordingPhase.stopping(.init(ref: ref, reason: .quit))
    let tr = stopping.applying(.captureStopped)
    #expect(tr.phase == .idle); #expect(tr.effects.isEmpty)
}

@Test func clockIgnoresJitterPadsGapsAndDropsOverlap() {
    var clock = TrackClock(sampleRate: 48_000, firstHostSeconds: 100)
    // 4096-frame chunks, 85.33 ms each, with +-30 ms jitter: always .append
    #expect(clock.placement(chunkHostSeconds: 100.03, frameCount: 4096) == .append)
    clock.commit(.append, chunkHostSeconds: 100.03, frameCount: 4096)
    // expected next start = 100 + 4096/48000 = 100.0853; arrive at 100.5 => ~0.415 s late => pad 19_9xx frames
    let p = clock.placement(chunkHostSeconds: 100.5, frameCount: 4096)
    guard case .padSilence(let n) = p else { Issue.record("expected pad"); return }
    #expect(abs(Double(n) / 48_000 - 0.4147) < 0.001)
    clock.commit(p, chunkHostSeconds: 100.5, frameCount: 4096)
    #expect(clock.gapCount == 1)
    // After padding, file time == host time again: the next contiguous chunk is .append
    let next = 100.5 + 4096.0 / 48_000
    #expect(clock.placement(chunkHostSeconds: next, frameCount: 4096) == .append)
    // A single-step backward jump (duplicated audio) drops its head, never more than the chunk's length
    #expect(clock.placement(chunkHostSeconds: next - 0.8, frameCount: 4096) == .dropLeading(frames: 4096))
}

/// Steady drift, simulated for 2 h of 4096-frame chunks. Returns the clock and the number of non-append placements by kind.
private func simulate(deviceRatio: Double) -> (clock: TrackClock, pads: Int, drops: Int, hostEnd: Double) {
    var clock = TrackClock(sampleRate: 48_000, firstHostSeconds: 1_000)
    var pads = 0, drops = 0
    let chunk = 4096.0, chunks = Int(7_200.0 * 48_000 / chunk)
    for i in 0..<chunks {
        // host time of chunk i: the device produces one chunk of frames in chunk / (rate * deviceRatio) host seconds
        let host = 1_000 + Double(i) * chunk / (48_000 * deviceRatio)
        let p = clock.placement(chunkHostSeconds: host, frameCount: 4096)
        switch p { case .append: break; case .padSilence: pads += 1; case .dropLeading: drops += 1 }
        clock.commit(p, chunkHostSeconds: host, frameCount: 4096)
    }
    return (clock, pads, drops, 1_000 + Double(chunks) * chunk / (48_000 * deviceRatio))
}

@Test func fastDeviceClockNeverDeletesSpeech() {
    let r = simulate(deviceRatio: 1.0001)       // device 100 ppm fast: the file runs AHEAD of host time
    #expect(r.drops == 0); #expect(r.pads == 0)
    #expect(r.clock.overlapDroppedFrames == 0)
    #expect(r.clock.maxAbsDriftSeconds > 0.6)   // ~0.72 s ahead after 2 h: recorded, not corrected
}

@Test func slowDeviceClockIsPaddedWithSilenceOnly() {
    let r = simulate(deviceRatio: 0.9999)       // device 100 ppm slow: the file falls behind host time
    #expect(r.drops == 0); #expect(r.pads >= 5)
    let padded = Double(r.clock.gapFillFrames) / 48_000
    #expect(padded > 0.55 && padded < 0.75)
}

@Test func captureLeaseIsExclusiveAndReleasedWithTheHolder() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lock")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(!CaptureLease.isHeld(url))                 // no file yet: free
    var lease: CaptureLease? = try #require(CaptureLease.acquire(url))
    #expect(CaptureLease.isHeld(url))
    #expect(CaptureLease.acquire(url) == nil)          // second holder (even in-process) is refused
    lease?.release(); #expect(!CaptureLease.isHeld(url))
    lease = try #require(CaptureLease.acquire(url)); #expect(CaptureLease.isHeld(url))
    lease = nil                                        // dropping the holder releases it (process death does the same)
    #expect(!CaptureLease.isHeld(url))
}

@Test func metaRoundTripsAndRejectsHalfFinishedCapture() throws {
    let meta = SessionMeta(id: UUID(), company: "Acme", title: "二次面接", timeZone: "Asia/Tokyo", startedAt: t0,
                           app: .init(version: "0.1.0", build: "1", os: "27.2"),
                           tracks: .init(me: .init(source: .mic(deviceUID: "uid", deviceName: "Rubix44", channel: 1, deviceChannels: 4)),
                                         remote: .init(source: .app(bundleID: "com.google.Chrome", name: "Google Chrome"))))
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let data = try enc.encode(meta)
    #expect(try dec.decode(SessionMeta.self, from: data) == meta)
    #expect(String(decoding: data, as: UTF8.self).contains("\"self\""))   // JSON key is "self", not "me"

    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["endedAt"] = "2026-11-09T07:00:00Z"   // endReason missing
    let bad = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: DecodingError.self) { try dec.decode(SessionMeta.self, from: bad) }
}
