import Foundation

// MARK: - Engine boundary (plain DTOs; no WhisperKit type ever crosses into Core)

/// What the app-side adapter copies out of the engine's result, field for field. Floats as the engine reports them.
/// The adapter is a one-line `map`; all interpretation lives in `EngineOutput.normalize` (pure, tested).
public struct EngineSegmentDTO: Sendable, Equatable {
    public var start: Float, end: Float
    public var text: String
    public var avgLogprob: Float, noSpeechProb: Float, compressionRatio: Float
    public init(start: Float, end: Float, text: String, avgLogprob: Float, noSpeechProb: Float, compressionRatio: Float) {
        self.start = start; self.end = end; self.text = text
        self.avgLogprob = avgLogprob; self.noSpeechProb = noSpeechProb; self.compressionRatio = compressionRatio
    }
}

/// A normalized engine segment in the *track's own* time (seconds from the first sample of its file).
public struct EngineSegment: Sendable, Equatable {
    public var start: Double, end: Double
    public var text: String
    public var avgLogprob: Double, noSpeechProb: Double, compressionRatio: Double
}

public enum EngineOutput {
    /// Pure. Strips Whisper control tokens (`<|ja|>`, `<|12.34|>`, `<|endoftext|>`), trims and collapses whitespace,
    /// drops empty text, replaces NaN/inf with neutral values, clamps `end >= start` and both into `0...audioDuration`,
    /// rounds to milliseconds, and sorts by (start, end).
    public static func normalize(_ dto: [EngineSegmentDTO], audioDuration: Double) -> [EngineSegment] {
        let upper: Double? = audioDuration.isFinite && audioDuration > 0
            ? (audioDuration * 1000).rounded(.down) / 1000 : nil
        func time(_ value: Float, fallback: Double) -> Double {
            let finite = value.isFinite ? Double(value) : fallback
            let rounded = (max(0, finite) * 1000).rounded() / 1000
            return upper.map { min($0, rounded) } ?? rounded
        }
        return dto.enumerated().compactMap { index, value -> (Int, EngineSegment)? in
            let stripped = value.text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            let text = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { return nil }
            let start = time(value.start, fallback: 0)
            let end = max(start, time(value.end, fallback: start))
            return (index, EngineSegment(start: start, end: end, text: text,
                avgLogprob: value.avgLogprob.isFinite ? Double(value.avgLogprob) : 0,
                noSpeechProb: value.noSpeechProb.isFinite ? Double(value.noSpeechProb) : 0,
                compressionRatio: value.compressionRatio.isFinite ? Double(value.compressionRatio) : 1))
        }.sorted {
            if $0.1.start != $1.1.start { return $0.1.start < $1.1.start }
            if $0.1.end != $1.1.end { return $0.1.end < $1.1.end }
            return $0.0 < $1.0
        }.map(\.1)
    }
}

// MARK: - segments.json

/// One utterance on the *session timeline* (t = 0 is the earliest first sample of either track).
/// This is the element type of segments.json's `segments` array. Engine confidence fields are kept so that
/// filtering (hallucination policy) and coalescing happen at read time and can improve without re-transcribing.
public struct TimelineSegment: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    /// DESIGN §6 calls this `speaker`. In Phase 1 it is exactly the track the audio came from.
    public var speaker: Track
    public var text: String
    public var avgLogprob: Double
    public var noSpeechProb: Double
    public var compressionRatio: Double
}

public struct TranscriberIdentity: Sendable, Equatable, Codable {
    public var engine: String          // "whisperkit"
    public var engineVersion: String?  // package version, informational
    public var model: String           // exact HF folder name, e.g. "openai_whisper-large-v3-v20240930_turbo"
    public var language: String        // "ja"; explicit, never auto-detected
    public var chunking: String        // "vad" | "none"
    public init(engine: String, engineVersion: String?, model: String, language: String, chunking: String) {
        self.engine = engine; self.engineVersion = engineVersion; self.model = model
        self.language = language; self.chunking = chunking
    }
}

public enum TrackTranscriptionStatus: String, Sendable, Equatable, Codable {
    case transcribed
    case skippedSilent      // peak <= -70 dBFS: nothing to say, nothing run
    case skippedNoAudio     // track never produced audio
}

public struct SegmentsFile: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var createdAt: Date
    public var transcriber: TranscriberIdentity
    public var tracks: PerTrack<TrackTranscriptionStatus>
    /// Sorted by `TimelineBuilder`'s total order. Unfiltered engine output.
    public var segments: [TimelineSegment]
}
