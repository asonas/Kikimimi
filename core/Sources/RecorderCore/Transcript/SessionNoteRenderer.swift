import Foundation

public enum SessionNoteRenderer {
    public static func render(meta: SessionMeta, segments: SegmentsFile, summary: String?, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: meta.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: meta.startedAt)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        var lines = ["---", "type: interview-log", "source: kikimimi", "session: \(meta.id.uuidString)",
                     "company: \(YAMLScalar.quoted(meta.company))"]
        if let title = meta.title { lines.append("title: \(YAMLScalar.quoted(title))") }
        lines += ["date: \(YAMLScalar.quoted(date))", "started: \(YAMLScalar.quoted(formatter.string(from: meta.startedAt)))",
                  "duration: \(YAMLScalar.quoted(TranscriptTimestamp.format(SessionTimeline.duration(of: meta))))"]
        if let event = meta.event {
            lines += ["event: \(YAMLScalar.quoted(event.title))", "event_start: \(YAMLScalar.quoted(formatter.string(from: event.start)))"]
            if let url = event.meetingURL { lines.append("meeting_url: \(YAMLScalar.quoted(url.absoluteString))") }
        }
        lines += ["exported: \(YAMLScalar.quoted(formatter.string(from: now)))", "---", "",
                  "# \(TranscriptRenderer.heading(meta.company)) \(TranscriptRenderer.heading(meta.title ?? "面接"))（\(date)）", ""]
        if let summary {
            lines += ["## 要約", "", demoteHeadings(summary).trimmingCharacters(in: .newlines), ""]
        }
        lines += ["## 書き起こし", ""]
        lines += TranscriptReader.lines(from: segments.segments).map {
            "[\($0.timestamp) \($0.speaker == .me ? "自分" : "相手")] \($0.text)"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func demoteHeadings(_ markdown: String) -> String {
        var fence: (character: Character, length: Int)?
        return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { value -> String in
            let line = String(value)
            let content = line.trimmingCharacters(in: .whitespaces)
            if let first = content.first, first == "`" || first == "~" {
                let count = content.prefix(while: { $0 == first }).count
                if let current = fence {
                    if first == current.character, count >= current.length,
                       content.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                } else if count >= 3 { fence = (first, count) }
                return line
            }
            guard fence == nil else { return line }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " { return "#" + line }
            return line
        }.joined(separator: "\n")
    }
}

public enum SessionExportFreshness {
    /// meta.json dates have second precision; changes in the export's own second were already read.
    public static func isOutdated(exportedAt: Date, modifiedAt: [Date]) -> Bool {
        modifiedAt.contains { floor($0.timeIntervalSince1970) > floor(exportedAt.timeIntervalSince1970) }
    }
}
