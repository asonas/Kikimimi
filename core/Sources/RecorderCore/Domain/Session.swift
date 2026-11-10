import Foundation

/// What the user types in the "new recording" window.
public struct SessionDraft: Sendable, Equatable {
    public var company: String          // required, non-empty after trimming
    public var title: String?           // optional round label, e.g. "二次面接"
    public var remote: RemoteSource
    public var event: SessionEvent?
    public init(company: String, title: String? = nil, remote: RemoteSource, event: SessionEvent? = nil) {
        self.company = company; self.title = title; self.remote = remote
        self.event = event
    }
}

/// Snapshot of the scheduled event at recording start; independent of later calendar edits.
public struct SessionEvent: Sendable, Equatable, Codable {
    public let title: String
    public let start: Date
    public let end: Date
    public let meetingURL: URL?
    public let calendarTitle: String

    public init(title: String, start: Date, end: Date, meetingURL: URL?, calendarTitle: String) {
        self.title = title; self.start = start; self.end = end
        self.meetingURL = meetingURL; self.calendarTitle = calendarTitle
    }

    public init(_ event: CalendarEvent) {
        self.init(title: event.title, start: event.start, end: event.end,
                  meetingURL: event.meetingURL, calendarTitle: event.calendarTitle)
    }
}

/// Which audio is "the remote side". Persisted in Settings (last choice) and meta.json.
public enum RemoteSource: Sendable, Equatable, Codable {
    case app(bundleID: String, name: String)
    case allSystemAudio   // everything except this process; leaks other apps' sounds (documented)
}

/// The single place that knows the files inside a session folder.
/// Every other module asks for a URL here; no string literals for file names anywhere else.
public struct SessionFolder: Sendable, Hashable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public var meta: URL { url.appendingPathComponent("meta.json") }
    public var segments: URL { url.appendingPathComponent("segments.json") }
    public var transcript: URL { url.appendingPathComponent("transcript.md") }
    public var transcriptBackup: URL { url.appendingPathComponent("transcript.prev.md") }
    public var summary: URL { url.appendingPathComponent("summary.md") }
    public var summaryBackup: URL { url.appendingPathComponent("summary.prev.md") }
    /// Advisory flock held by the capturing process for the whole capture (see CaptureLease). Liveness is a kernel fact.
    public var lock: URL { url.appendingPathComponent("capture.lock") }

    /// Crash-safe PCM spool written during capture (CAF, LPCM int16, mono). Deleted after finalize.
    public func spool(_ t: Track) -> URL { url.appendingPathComponent("audio-\(t.rawValue).spool.caf") }
    /// Final AAC artifact. Appears atomically (written as `.m4a.part`, then renamed).
    public func audio(_ t: Track) -> URL { url.appendingPathComponent("audio-\(t.rawValue).m4a") }
    public func audioPart(_ t: Track) -> URL { url.appendingPathComponent("audio-\(t.rawValue).m4a.part") }
}

/// Stable identity of a recorded session. `id` lives in meta.json; the folder name is a label only
/// (the user may rename the folder in Finder and nothing breaks).
public struct SessionRef: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let folder: SessionFolder
    public init(id: UUID, folder: SessionFolder) { self.id = id; self.folder = folder }
}

/// Why a capture ended. `recovered` is only ever written by finalize-on-launch.
public enum EndReason: String, Codable, Sendable, Equatable {
    case user, quit, captureLost, recovered
}

/// A failure of one track. The other track keeps recording.
public struct TrackFailure: Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case deviceLost, formatChanged, targetAppQuit, streamStopped, writeFailed, noAudioEver
    }
    public var code: Code
    public var message: String
    /// Seconds on the track's own file timeline when it happened (nil if unknown).
    public var atSeconds: Double?
    public init(code: Code, message: String, atSeconds: Double? = nil) {
        self.code = code; self.message = message; self.atSeconds = atSeconds
    }
}
