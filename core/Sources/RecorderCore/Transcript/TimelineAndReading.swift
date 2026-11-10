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
    enum BuildError: Error, Sendable, Equatable { case missingOffset(Track) }

    static func build(tracks: PerTrack<[EngineSegment]>, offsets: PerTrack<Double>) throws -> [TimelineSegment] {
        var merged: [(TimelineSegment, Int)] = []
        for (track, segments) in tracks.present {
            guard !segments.isEmpty else { continue }
            guard let offset = offsets[track] else { throw BuildError.missingOffset(track) }
            for (index, value) in segments.enumerated() {
                merged.append((TimelineSegment(start: value.start + offset, end: value.end + offset,
                    speaker: track, text: value.text, avgLogprob: value.avgLogprob,
                    noSpeechProb: value.noSpeechProb, compressionRatio: value.compressionRatio), index))
            }
        }
        return merged.sorted {
            if $0.0.start != $1.0.start { return $0.0.start < $1.0.start }
            if $0.0.end != $1.0.end { return $0.0.end < $1.0.end }
            if $0.0.speaker != $1.0.speaker { return $0.0.speaker.mergeRank < $1.0.speaker.mergeRank }
            return $0.1 < $1.1
        }.map(\.0)
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
    /// Drop exact normalized stock phrases ("ご視聴ありがとうございました" etc.), regardless of confidence.
    var stockHallucinations: Set<String> = ["ご視聴ありがとうございました", "チャンネル登録お願いします", "字幕:"]
    /// Merge consecutive same-speaker segments if the gap is below this and the merged line stays under `maxLineSeconds`.
    var coalesceGap = 2.0, maxLineSeconds = 45.0
    static let standard = ReadingPolicy()

    func excludes(_ segment: TimelineSegment) -> Bool {
        if segment.noSpeechProb > noSpeechMax && segment.avgLogprob < logprobMin { return true }
        if segment.compressionRatio > compressionRatioMax { return true }
        if dropSymbolOnly && !segment.text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) { return true }
        func phrase(_ text: String) -> String {
            var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = text.unicodeScalars.last, CharacterSet.punctuationCharacters.contains(last) {
                text.unicodeScalars.removeLast()
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stockHallucinations.contains { phrase($0) == phrase(segment.text) }
    }
}

public struct TranscriptLine: Sendable, Equatable {
    public internal(set) var start: Double
    public internal(set) var speaker: Track
    public internal(set) var text: String
    /// Same timeline timestamp used in Markdown, including recordings longer than 24 hours.
    public var timestamp: String { TranscriptTimestamp.format(start) }
}

enum TranscriptReader {
    /// filter -> coalesce. Pure.
    static func lines(from segments: [TimelineSegment], policy: ReadingPolicy = .standard) -> [TranscriptLine] {
        var result: [(line: TranscriptLine, end: Double)] = []
        for segment in segments where !policy.excludes(segment) {
            if let last = result.last, last.line.speaker == segment.speaker,
               segment.start - last.end < policy.coalesceGap,
               max(last.end, segment.end) - last.line.start < policy.maxLineSeconds {
                result[result.count - 1].line.text += " " + segment.text
                result[result.count - 1].end = max(last.end, segment.end)
            } else {
                result.append((TranscriptLine(start: segment.start, speaker: segment.speaker, text: segment.text), segment.end))
            }
        }
        return result.map(\.line)
    }
}

// MARK: - Markdown

enum TranscriptRenderer {
    /// DESIGN §6 format. Front matter values are emitted as YAML double-quoted scalars with escaping
    /// (company names may contain ':' '"' '#'). Labels: self -> "自分", remote -> "相手".
    /// Timestamp is HH:MM:SS from timeline start, floor-ed, hours not capped at 24.
    /// Heading: "# {company} {title ?? "面接"}（{yyyy-MM-dd}）", date in meta.timeZone.
    static func render(meta: SessionMeta, segments: SegmentsFile, policy: ReadingPolicy = .standard) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: meta.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: meta.startedAt)
        var lines = ["---", "type: interview-log", "company: \(YAMLScalar.quoted(meta.company))", "date: \(YAMLScalar.quoted(date))",
                     "duration: \(YAMLScalar.quoted(TranscriptTimestamp.format(SessionTimeline.duration(of: meta))))", "---", "",
                     "# \(heading(meta.company)) \(heading(meta.title ?? "面接"))（\(date)）", ""]
        if let event = meta.event {
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            lines += ["予定: \(heading(event.title))（\(formatter.string(from: event.start))〜\(formatter.string(from: event.end))）", ""]
        }
        lines += TranscriptReader.lines(from: segments.segments, policy: policy).map {
            "[\($0.timestamp) \($0.speaker == .me ? "自分" : "相手")] \($0.text)"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func heading(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

enum YAMLScalar {
    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x0a: result += "\\n"
            case 0x0d: result += "\\r"
            case 0x09: result += "\\t"
            case 0...0x1f, 0x7f...0x9f, 0x2028, 0x2029: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

enum TranscriptTimestamp {
    static func format(_ seconds: Double) -> String {
        let whole = seconds.isFinite ? max(0, seconds.rounded(.down)) : 0
        return String(format: "%02.0f:%02.0f:%02.0f", (whole / 3600).rounded(.down),
            (whole.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down), whole.truncatingRemainder(dividingBy: 60))
    }
}
