import Foundation

// MARK: - Session timeline

/// Pure. Owns the rule "how do two independently started tracks become one timeline".
enum SessionTimeline {
    /// t = 0 is the earliest `firstSampleHostSeconds` among present tracks. Offsets are therefore all >= 0.
    /// Derived on demand; never stored (meta.json keeps only the first-sample facts).
    static func offsets(of tracks: PerTrack<TrackMeta>) -> PerTrack<Double> {
        guard let origin = tracks.present.compactMap({ $0.1.firstSampleHostSeconds }).min() else { return .init() }
        return .init(me: tracks.me?.firstSampleHostSeconds.map { $0 - origin },
                     remote: tracks.remote?.firstSampleHostSeconds.map { $0 - origin })
    }

    /// max over tracks of (offset + audio duration). The only definition of "duration" in the system.
    static func duration(of meta: SessionMeta) -> Double {
        let offsets = offsets(of: meta.tracks)
        return meta.tracks.present.compactMap { track, value in
            guard let audio = value.audio, let offset = offsets[track] else { return nil as Double? }
            return offset + audio.durationSeconds
        }.max() ?? 0
    }
}

/// Pure. Shifts each track's engine segments by its offset and merges into one total order:
/// (start, end, track.mergeRank, original index). Deterministic, so tests can compare whole arrays.
enum TimelineBuilder {
    static func build(tracks: PerTrack<[EngineSegment]>, offsets: PerTrack<Double>) -> [TimelineSegment] {
        fatalError("not implemented")
    }
}

// MARK: - Reading policy (applied at render time, never persisted)

struct ReadingPolicy: Sendable, Equatable {
    /// Drop when `noSpeechProb > noSpeechMax && avgLogprob < logprobMin` (Whisper's own silence rule).
    var noSpeechMax = 0.6, logprobMin = -1.0
    /// Drop repetition loops.
    var compressionRatioMax = 2.4
    /// Drop text with no letters/digits/CJK (".", "…", "♪").
    var dropSymbolOnly = true
    /// Drop short low-confidence stock phrases ("ご視聴ありがとうございました" etc.). Single list, here.
    var stockHallucinations: Set<String> = ["ご視聴ありがとうございました", "チャンネル登録お願いします", "字幕:"]
    var stockLogprobMax = -0.5
    /// Merge consecutive same-speaker segments if the gap is below this and the merged line stays under `maxLineSeconds`.
    var coalesceGap = 2.0, maxLineSeconds = 45.0
    static let standard = ReadingPolicy()
}

struct TranscriptLine: Sendable, Equatable {
    var start: Double
    var speaker: Track
    var text: String
}

enum TranscriptReader {
    /// filter -> coalesce. Pure.
    static func lines(from segments: [TimelineSegment], policy: ReadingPolicy = .standard) -> [TranscriptLine] {
        fatalError("not implemented")
    }
}

// MARK: - Markdown

enum TranscriptRenderer {
    /// DESIGN §6 format. Front matter values are emitted as YAML double-quoted scalars with escaping
    /// (company names may contain ':' '"' '#'). Labels: self -> "自分", remote -> "相手".
    /// Timestamp is HH:MM:SS from timeline start, floor-ed, hours not capped at 24.
    /// Heading: "# {company} {title ?? "面接"}（{yyyy-MM-dd}）", date in meta.timeZone.
    static func render(meta: SessionMeta, segments: SegmentsFile, policy: ReadingPolicy = .standard) -> String {
        fatalError("not implemented")
    }
}
