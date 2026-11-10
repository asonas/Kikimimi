import Foundation
import Testing
@testable import RecorderCore

private func noteDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private let noteNow = noteDate("2026-11-10T06:30:00Z")

private func noteMeta() -> SessionMeta {
    SessionMeta(id: UUID(uuidString: "00000000-0000-0000-0000-000000000116")!, company: "会社A", title: nil,
                timeZone: "Asia/Tokyo", startedAt: noteDate("2026-11-10T04:00:00Z"),
                app: .init(version: "1", build: "1", os: "test"),
                tracks: .init(me: .init(source: .allSystemAudio, firstSampleHostSeconds: 100,
                                       audio: .init(file: "self", sampleRate: 48_000, frames: 3_163_200, peakDBFS: -6))))
}

private func noteSegments() -> SegmentsFile {
    SegmentsFile(schemaVersion: 1, createdAt: noteNow,
                 transcriber: .init(engine: "test", engineVersion: nil, model: "test", language: "ja", chunking: "vad"),
                 tracks: .init(me: .transcribed, remote: .transcribed), segments: [
                    .init(start: 12, end: 13, speaker: .remote, text: "自己紹介をお願いします。", avgLogprob: -0.1, noSpeechProb: 0, compressionRatio: 1),
                    .init(start: 14, end: 14.5, speaker: .me, text: "ご視聴ありがとうございました。", avgLogprob: -0.1, noSpeechProb: 0, compressionRatio: 1),
                    .init(start: 15, end: 16, speaker: .me, text: "よろしくお願いします。", avgLogprob: -0.1, noSpeechProb: 0, compressionRatio: 1)
                 ])
}

private func noteGolden(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func sessionNoteMatchesGoldenWithoutSummaryOrEvent() throws {
    let expected = try noteGolden("note-basic")
    let output = SessionNoteRenderer.render(meta: noteMeta(), segments: noteSegments(), summary: nil, now: noteNow)
    #expect(output == expected)
    #expect(!output.contains("## 要約"))
    #expect(!output.contains("ご視聴"))
}

@Test func sessionNoteMatchesGoldenWithSummaryAndEvent() throws {
    var meta = noteMeta()
    meta.title = "一次面接"
    meta.event = SessionEvent(title: "会社A 面接", start: noteDate("2026-11-10T03:00:00Z"),
                              end: noteDate("2026-11-10T04:00:00Z"), meetingURL: URL(string: "https://meet.google.com/abc"), calendarTitle: "仕事")
    let expected = try noteGolden("note-summary-event")
    let output = SessionNoteRenderer.render(meta: meta, segments: noteSegments(),
                                          summary: "## 概要\n\n面接の要点。\n\n### 条件\n\n- リモート勤務\n", now: noteNow)
    #expect(output == expected)
}

@Test func sessionNoteDemotesHeadingsButPreservesTextAndFencedCode() {
    let input = "# A\n## B\n### C\n本文\n- **項目**\n```md\n## コード内\n```\n~~~\n### コード内\n~~~\n"
    let expected = "## A\n### B\n#### C\n本文\n- **項目**\n```md\n## コード内\n```\n~~~\n### コード内\n~~~\n"
    #expect(SessionNoteRenderer.demoteHeadings(input) == expected)
}

@Test func sessionNoteEscapesYAMLAndUsesPersistedTimeZoneForDates() {
    var meta = noteMeta()
    meta.company = "A: \"B\"\n次"
    meta.title = "二次:\t確認\\メモ"
    meta.event = SessionEvent(title: "予定\n\"確認\"", start: meta.startedAt, end: meta.startedAt,
                              meetingURL: nil, calendarTitle: "仕事")
    meta.timeZone = "UTC"
    let output = SessionNoteRenderer.render(meta: meta, segments: noteSegments(), summary: nil, now: noteNow)
    #expect(output.contains("company: \"A: \\\"B\\\"\\n次\"\n"))
    #expect(output.contains("title: \"二次:\\t確認\\\\メモ\"\n"))
    #expect(output.contains("event: \"予定\\n\\\"確認\\\"\"\n"))
    #expect(!output.contains("meeting_url:"))
    #expect(output.contains("started: \"2026-11-10T04:00:00+00:00\""))
    #expect(output.contains("exported: \"2026-11-10T06:30:00+00:00\""))
}

@Test func sessionExportFreshnessComparesWholeSecondsOnly() {
    let exported = Date(timeIntervalSince1970: 100.7)
    #expect(!SessionExportFreshness.isOutdated(exportedAt: exported, modifiedAt: []))
    #expect(!SessionExportFreshness.isOutdated(exportedAt: exported, modifiedAt: [.init(timeIntervalSince1970: 99.9)]))
    #expect(!SessionExportFreshness.isOutdated(exportedAt: exported, modifiedAt: [.init(timeIntervalSince1970: 100.99)]))
    #expect(SessionExportFreshness.isOutdated(exportedAt: exported,
                                             modifiedAt: [.init(timeIntervalSince1970: 100), .init(timeIntervalSince1970: 101)]))
}

@Test func oldSettingsDecodeWithoutExportFolderAndRoundTripConfiguredPath() throws {
    let data = Data(#"{"language":"ja","modelVariant":"test","screenCaptureRequested":false}"#.utf8)
    var settings = try JSONDecoder().decode(Settings.self, from: data)
    #expect(settings.exportFolder == nil)
    settings.exportFolder = "/tmp/Interview Notes"
    #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
}
