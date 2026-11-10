import Foundation
import Testing
@testable import RecorderCore

private func dto(_ text: String = "音声", start: Float = 0, end: Float = 1,
                 logprob: Float = -0.2, noSpeech: Float = 0.01, compression: Float = 1) -> EngineSegmentDTO {
    .init(start: start, end: end, text: text, avgLogprob: logprob, noSpeechProb: noSpeech, compressionRatio: compression)
}

private func segment(_ text: String = "音声", start: Double = 0, end: Double = 1, speaker: Track = .me,
                     logprob: Double = -0.2, noSpeech: Double = 0.01, compression: Double = 1) -> TimelineSegment {
    .init(start: start, end: end, speaker: speaker, text: text, avgLogprob: logprob, noSpeechProb: noSpeech, compressionRatio: compression)
}

private func transcriptMeta(company: String = "Acme", title: String? = "二次面接", zone: String = "Asia/Tokyo",
                            duration: Double = 5706) -> SessionMeta {
    .init(id: UUID(), company: company, title: title, timeZone: zone,
          startedAt: Date(timeIntervalSince1970: 1_794_238_200),
          app: .init(version: "1", build: "1", os: "test"),
          tracks: .init(me: .init(source: .allSystemAudio, firstSampleHostSeconds: 100,
                                 audio: .init(file: "self", sampleRate: 48_000, frames: Int64(duration * 48_000), peakDBFS: -6))))
}

private func transcriptFile(_ segments: [TimelineSegment]) -> SegmentsFile {
    .init(schemaVersion: 1, createdAt: Date(timeIntervalSince1970: 0),
          transcriber: .init(engine: "fake", engineVersion: nil, model: "test", language: "ja", chunking: "vad"),
          tracks: .init(me: .transcribed, remote: .transcribed), segments: segments)
}

private func golden(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func normalizeStripsControlTokensCollapsesWhitespaceAndDropsEmptyText() {
    let output = EngineOutput.normalize([
        dto(" <|ja|> \n はい、\t藤原です。 <|12.34|><|endoftext|> "),
        dto("<|startoftranscript|>\n <|endoftext|>"), dto(" \t　\n"), dto("<ordinary>"),
    ], audioDuration: 10)
    #expect(output.map(\.text) == ["はい、 藤原です。", "<ordinary>"])
}

@Test func normalizeClampsTimesRoundsMillisecondsAndRepairsReversedEnd() {
    let output = EngineOutput.normalize([
        dto("negative", start: -2, end: -1), dto("round", start: 1.2346, end: 1.9996),
        dto("reversed", start: 3, end: 2), dto("past end", start: 20, end: 30),
    ], audioDuration: 5)
    #expect(output.map(\.start) == [0, 1.235, 3, 5])
    #expect(output.map(\.end) == [0, 2, 3, 5])
    let capped = EngineOutput.normalize([dto(start: 1.2346, end: 2)], audioDuration: 1.2345)
    #expect(capped.first?.start == 1.234)
    #expect(capped.first?.end == 1.234)
}

@Test func normalizeReplacesNonfiniteValuesWithAgreedNeutralValues() {
    for invalid in [Float.nan, .infinity, -.infinity] {
        let output = EngineOutput.normalize([dto(start: invalid, end: invalid, logprob: invalid, noSpeech: invalid, compression: invalid)], audioDuration: 10)
        #expect(output.first == .init(start: 0, end: 0, text: "音声", avgLogprob: 0, noSpeechProb: 0, compressionRatio: 1))
        let endFallback = EngineOutput.normalize([dto(start: 2, end: invalid)], audioDuration: 10)
        #expect(endFallback.first?.end == 2)
    }
}

@Test func normalizeUnknownOrNonpositiveDurationPreservesTimesWithoutUpperClamp() {
    for duration in [0.0, -1, .nan, .infinity, -.infinity] {
        let output = EngineOutput.normalize([dto(start: 10, end: 12), dto("negative", start: -1, end: 1)], audioDuration: duration)
        #expect(output.map(\.start) == [0, 10])
        #expect(output.map(\.end) == [1, 12])
    }
}

@Test func normalizeSortsByStartEndAndPreservesOriginalOrderForTies() {
    let output = EngineOutput.normalize([dto("late", start: 3, end: 4), dto("tie first", start: 1, end: 2),
                                         dto("short", start: 1, end: 1.5), dto("tie second", start: 1, end: 2)], audioDuration: 10)
    #expect(output.map(\.text) == ["short", "tie first", "tie second", "late"])
}

@Test func timelineOffsetsAndMergePreserveConfidenceAndRemoteTieOrder() throws {
    let mine = EngineOutput.normalize([dto("self", start: 1, end: 2, logprob: -0.5, noSpeech: 0.25, compression: 1.5)], audioDuration: 10)
    let other = EngineOutput.normalize([dto("remote first", start: 1.5, end: 2.5), dto("remote second", start: 1.5, end: 2.5)], audioDuration: 10)
    let result = try TimelineBuilder.build(tracks: .init(me: mine, remote: other), offsets: .init(me: 0.5, remote: 0))
    #expect(result.map(\.text) == ["remote first", "remote second", "self"])
    #expect(result.map(\.start) == [1.5, 1.5, 1.5])
    #expect(result.last == segment("self", start: 1.5, end: 2.5, logprob: -0.5, noSpeech: 0.25, compression: 1.5))
}

@Test func timelineMergeIsStableAcrossShuffledDistinctSegments() throws {
    let raw = [dto("three", start: 3, end: 4), dto("one", start: 1, end: 2), dto("two", start: 2, end: 3)]
    let expected = try TimelineBuilder.build(tracks: .init(remote: EngineOutput.normalize(raw, audioDuration: 10)), offsets: .init(remote: 2))
    for input in [raw, Array(raw.reversed()), [raw[1], raw[0], raw[2]]] {
        let normalized = EngineOutput.normalize(input, audioDuration: 10)
        #expect(try TimelineBuilder.build(tracks: .init(remote: normalized), offsets: .init(remote: 2)) == expected)
    }
    #expect(expected.map(\.start) == [3, 4, 5])
}

@Test func timelineMissingOffsetRejectsSpeechButAllowsEmptyTrack() throws {
    let speech = EngineOutput.normalize([dto()], audioDuration: 10)
    #expect(throws: TimelineBuilder.BuildError.missingOffset(.me)) {
        try TimelineBuilder.build(tracks: .init(me: speech), offsets: .init())
    }
    #expect(throws: TimelineBuilder.BuildError.missingOffset(.remote)) {
        try TimelineBuilder.build(tracks: .init(remote: speech), offsets: .init(me: 0))
    }
    #expect(try TimelineBuilder.build(tracks: .init(me: [], remote: speech), offsets: .init(remote: 0)).count == 1)
    #expect(try TimelineBuilder.build(tracks: .init(), offsets: .init()).isEmpty)
}

@Test func readingPolicyNoSpeechRuleNeedsBothStrictConditions() {
    let policy = ReadingPolicy.standard
    #expect(policy.excludes(segment(logprob: -1.001, noSpeech: 0.601)))
    #expect(!policy.excludes(segment(logprob: -1.001, noSpeech: 0.6)))
    #expect(!policy.excludes(segment(logprob: -1, noSpeech: 0.601)))
    #expect(!policy.excludes(segment(logprob: -0.2, noSpeech: 0.9)))
}

@Test func readingPolicyCompressionRuleUsesStrictThreshold() {
    #expect(ReadingPolicy.standard.excludes(segment(compression: 2.401)))
    #expect(!ReadingPolicy.standard.excludes(segment(compression: 2.4)))
}

@Test func readingPolicySymbolOnlyRuleKeepsUnicodeLettersAndNumbers() {
    for text in [".", "…", "♪", "！?", "😀", "　"] { #expect(ReadingPolicy.standard.excludes(segment(text))) }
    for text in ["漢字", "ひらがな", "カタカナ", "abc", "１２３", "123"] { #expect(!ReadingPolicy.standard.excludes(segment(text))) }
    var disabled = ReadingPolicy.standard; disabled.dropSymbolOnly = false
    #expect(!disabled.excludes(segment("♪")))
}

@Test func readingPolicyStockPhrasesRequireOnlyExactMatchRegardlessOfConfidence() {
    for text in ["ご視聴ありがとうございました", "ご視聴ありがとうございました。", " ご視聴ありがとうございました。 ", "チャンネル登録お願いします！", "字幕:"] {
        for logprob in [-0.501, -0.5, -0.1] {
            #expect(ReadingPolicy.standard.excludes(segment(text, logprob: logprob)))
        }
    }
    #expect(!ReadingPolicy.standard.excludes(segment("本日はありがとうございました。", logprob: -0.8)))
    #expect(!ReadingPolicy.standard.excludes(segment("ありがとうございました。")))
    #expect(!ReadingPolicy.standard.excludes(segment("ご視聴ありがとうございました、と発言した理由です", logprob: -0.8)))
    #expect(!ReadingPolicy.standard.excludes(segment("ご視聴ありがとうございましたと言われた", logprob: -0.1)))
}

@Test func transcriptReaderCoalescesOnlyBelowGapAndSpanBoundaries() {
    let rows: [([TimelineSegment], Int)] = [
        ([segment("a", end: 1), segment("b", start: 2.999, end: 3.5)], 1),
        ([segment("a", end: 1), segment("b", start: 3, end: 4)], 2),
        ([segment("a", end: 43), segment("b", start: 44, end: 44.999)], 1),
        ([segment("a", end: 43), segment("b", start: 44, end: 45)], 2),
        ([segment("a", end: 43), segment("b", start: 44, end: 45.001)], 2),
    ]
    for (input, count) in rows {
        let lines = TranscriptReader.lines(from: input)
        #expect(lines.count == count)
        if count == 1 { #expect(lines.first?.text == "a b"); #expect(lines.first?.start == 0) }
    }
}

@Test func transcriptReaderFiltersBeforeMergingAndPreservesSpeakerChanges() {
    let input = [segment("first"), segment("…", start: 1, end: 1.1, speaker: .remote),
                 segment("second", start: 1.5, end: 2), segment("question", start: 2.1, end: 3, speaker: .remote),
                 segment("answer", start: 3.1, end: 4)]
    let original = input
    let lines = TranscriptReader.lines(from: input)
    #expect(lines.map(\.text) == ["first second", "question", "answer"])
    #expect(lines.map(\.speaker) == [.me, .remote, .me])
    #expect(input == original)
}

@Test func transcriptReaderOverlapsKeepMaximumEndAndPolicyCanChange() {
    let input = [segment("long", end: 40), segment("overlap", start: 1, end: 2), segment("last", start: 40.5, end: 44)]
    #expect(TranscriptReader.lines(from: input).map(\.text) == ["long overlap last"])
    var policy = ReadingPolicy.standard; policy.maxLineSeconds = 10
    #expect(TranscriptReader.lines(from: input, policy: policy).count == 3)
}

@Test func transcriptRendererMatchesJapaneseGoldenThroughWholePipeline() throws {
    let me = EngineOutput.normalize([dto("<|ja|> はい、藤原と申します。", start: 220.804, end: 224.15),
                                     dto(" よろしくお願いします。 ", start: 225, end: 227)], audioDuration: 5706)
    let remote = EngineOutput.normalize([dto("では、まず自己紹介をお願いします。", start: 192.411, end: 197.02),
        dto("ご視聴ありがとうございました。", start: 500, end: 501, logprob: -0.8),
        dto("本日はありがとうございました。", start: 5700.9, end: 5705)], audioDuration: 5706)
    let merged = try TimelineBuilder.build(tracks: .init(me: me, remote: remote), offsets: .init(me: 0, remote: 0))
    let expected = try golden("transcript-japanese")
    #expect(TranscriptRenderer.render(meta: transcriptMeta(), segments: transcriptFile(merged)) == expected)
}

@Test func transcriptRendererMatchesEscapedAndLongDurationGolden() throws {
    let meta = transcriptMeta(company: "A: B \"x\"", title: nil, zone: "UTC", duration: 90001)
    let file = transcriptFile([segment("90分近く経ちました。", start: 5321.9, end: 5322),
        segment("90分を超えました。", start: 5700.9, end: 5701, speaker: .remote),
        segment("24時間を超えても折り返しません。", start: 90000.9, end: 90001)])
    let expected = try golden("transcript-long")
    #expect(TranscriptRenderer.render(meta: meta, segments: file) == expected)
}

@Test func transcriptRendererEscapesYamlControlsAndUsesUtcForUnknownZone() {
    let meta = transcriptMeta(company: "A\\B\nC\r\t\"#\u{0001}\u{0085}\u{2028}\u{2029}", title: "Title\nnext", zone: "invalid/timezone", duration: 5321)
    let output = TranscriptRenderer.render(meta: meta, segments: transcriptFile([]))
    #expect(output.contains(##"company: "A\\B\nC\r\t\"#\u0001\u0085\u2028\u2029""##))
    #expect(output.contains("date: \"2026-11-09\""))
    #expect(output.contains("duration: \"01:28:41\""))
    #expect(output.contains("Title next（2026-11-09）"))
}
