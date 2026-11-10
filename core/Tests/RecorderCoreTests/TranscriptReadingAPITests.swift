import Foundation
@testable import RecorderCore
import Testing

private func readingSession() async throws -> (SessionStore, SessionRef) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(root: root)
    let (ref, lease) = try await store.create(.init(company: "日本語: 会社", remote: .allSystemAudio),
        mic: .mic(deviceUID: "fake", deviceName: "Fake", channel: 1, deviceChannels: 1),
        remote: .allSystemAudio, app: .init(version: "1", build: "1", os: "test"))
    lease.release()
    return (store, ref)
}

private func readingFile(_ segments: [TimelineSegment], schema: Int = 1) -> SegmentsFile {
    .init(schemaVersion: schema, createdAt: Date(timeIntervalSince1970: 1000),
        transcriber: .init(engine: "fake", engineVersion: "1", model: "fake", language: "ja", chunking: "vad"),
        tracks: .init(me: .transcribed, remote: .transcribed), segments: segments)
}

private func readingSegment(_ start: Double, _ end: Double, _ text: String, speaker: Track = .me,
                            logprob: Double = -0.1, silence: Double = 0) -> TimelineSegment {
    .init(start: start, end: end, speaker: speaker, text: text,
          avgLogprob: logprob, noSpeechProb: silence, compressionRatio: 1)
}

@Test func transcriptLinesDistinguishesAbsentFromEmpty() async throws {
    let (store, ref) = try await readingSession(); defer { try? FileManager.default.removeItem(at: ref.folder.url.deletingLastPathComponent()) }
    #expect(try await store.transcriptLines(of: ref) == nil)
    try await store.saveTranscription(ref, readingFile([]))
    #expect(try await store.transcriptLines(of: ref) == [])
}

@Test func transcriptLinesRejectsCorruptAndNewerSchemaWithoutWriting() async throws {
    let (store, ref) = try await readingSession(); defer { try? FileManager.default.removeItem(at: ref.folder.url.deletingLastPathComponent()) }
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    for bytes in [Data("broken".utf8), try encoder.encode(readingFile([], schema: 2))] {
        try bytes.write(to: ref.folder.segments)
        await #expect(throws: (any Error).self) { try await store.transcriptLines(of: ref) }
        #expect(try Data(contentsOf: ref.folder.segments) == bytes)
        #expect(!FileManager.default.fileExists(atPath: ref.folder.transcript.path))
    }
}

@Test func transcriptLinesMatchesMarkdownPolicyAndLongTimestamps() async throws {
    let (store, ref) = try await readingSession(); defer { try? FileManager.default.removeItem(at: ref.folder.url.deletingLastPathComponent()) }
    try await store.saveTranscription(ref, readingFile([
        readingSegment(0, 1, "こんにちは", speaker: .remote), readingSegment(1.5, 2, "よろしく", speaker: .remote),
        readingSegment(2, 3, "ご視聴ありがとうございました", logprob: -2, silence: 0.9),
        readingSegment(3, 4, "…"), readingSegment(5, 6, "はい"), readingSegment(7, 8, "藤原です"),
        readingSegment(5700.9, 5702, "90分を超えました", speaker: .remote),
        readingSegment(90000.9, 90002, "24時間を超えました")]))
    let lines = try #require(try await store.transcriptLines(of: ref))
    #expect(lines.map(\.text) == ["こんにちは よろしく", "はい 藤原です", "90分を超えました", "24時間を超えました"])
    #expect(lines.map(\.timestamp) == ["00:00:00", "00:00:05", "01:35:00", "25:00:00"])
    #expect(lines.map(\.speaker) == [.remote, .me, .remote, .me])
    let rendered = lines.map { "[\($0.timestamp) \($0.speaker == .me ? "自分" : "相手")] \($0.text)" }
    let markdown = try String(contentsOf: ref.folder.transcript, encoding: .utf8)
    #expect(markdown.split(separator: "\n").filter { $0.hasPrefix("[") }.map(String.init) == rendered)
}

@Test func transcriptLinesReadPreservesHandEditedMarkdownAndSegments() async throws {
    let (store, ref) = try await readingSession(); defer { try? FileManager.default.removeItem(at: ref.folder.url.deletingLastPathComponent()) }
    try await store.saveTranscription(ref, readingFile([readingSegment(0, 1, "元の発話")]))
    let segments = try Data(contentsOf: ref.folder.segments)
    let edited = Data("# 手編集のメモ\n本文を残す\n".utf8)
    try edited.write(to: ref.folder.transcript)
    let lines = try #require(try await store.transcriptLines(of: ref))
    #expect(lines.map(\.text) == ["元の発話"])
    #expect(try Data(contentsOf: ref.folder.transcript) == edited)
    #expect(try Data(contentsOf: ref.folder.segments) == segments)
}
