import Foundation

// MARK: - Folder naming (pure)

enum FolderNamer {
    /// "2026-11-09_1500_Acme". Local time in `timeZone`.
    /// Sanitizing rules for the company part (all pure, all tested):
    ///  - NFC-normalize; replace `/ \ : * ? " < > |` and control chars with "-"; collapse whitespace runs to "_"
    ///  - trim leading/trailing "-", "_", "."  (no hidden or ".." names)
    ///  - Japanese and other non-ASCII letters are kept as is (APFS handles Unicode)
    ///  - truncate to 40 *characters* (grapheme clusters), never mid-cluster
    ///  - empty after sanitizing => "untitled"
    /// Collision: if `taken` contains the name, append "-2", "-3", ... (compare case-insensitively: APFS default).
    static func name(company: String, startedAt: Date, timeZone: TimeZone, taken: Set<String>) -> String {
        fatalError("not implemented")
    }
}

// MARK: - What a folder is, derived from what is in it (never stored)

/// Exclusive advisory lock (flock) on `SessionFolder.lock`, held by the capturing process from `create` until the session
/// is finalized or the process dies. The kernel releases it on process death, so "lock acquirable" means exactly "nobody is
/// capturing this folder". This replaces any reliance on single-instance enforcement for crash detection: a second app
/// instance, an Xcode Debug run next to an installed copy, or a recovery pass can never finalize a live interview.
public final class CaptureLease: @unchecked Sendable {
    private let mutex = NSLock()
    private var fd: Int32
    private init(fd: Int32) { self.fd = fd }

    /// Creates the file if needed and takes LOCK_EX|LOCK_NB. nil if another descriptor (any process) holds it.
    public static func acquire(_ url: URL) -> CaptureLease? {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }
        return CaptureLease(fd: fd)
    }
    /// True iff some descriptor holds the lock right now (including this process).
    public static func isHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }
    public func release() {
        mutex.lock(); defer { mutex.unlock() }
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN); close(fd); fd = -1
    }
    deinit { release() }
}

public enum SessionState: Sendable, Equatable {
    /// A process holds the capture lease: capture is live (possibly in another app instance). Never touched by recovery.
    case capturing
    /// Capture finished or crashed; spool files still exist or the m4a is missing. `finalize` fixes it.
    case needsFinalize
    /// Final audio present, no valid segments.json.
    case readyToTranscribe
    /// Valid segments.json for a supported schema (transcript.md is re-renderable from it).
    case transcribed
    /// Not ours to touch: unreadable meta, newer schema, or nothing recoverable.
    case unusable(String)
}

/// Observable facts about a folder, collected by `SessionStore` (the only code that touches the filesystem),
/// then classified by a pure function. This is what makes recovery and re-transcription testable without IO.
struct FolderInventory: Sendable, Equatable {
    var meta: Result<SessionMeta, InventoryProblem>
    var lockHeld: Bool                 // CaptureLease.isHeld(folder.lock)
    var spoolExists: PerTrack<Bool>
    var finalAudioExists: PerTrack<Bool>
    var segmentsDecodes: Bool          // exists and decodes at a supported schemaVersion
}
enum InventoryProblem: Error, Sendable, Equatable { case missing, undecodable(String), newerSchema(Int) }

enum SessionClassifier {
    /// Rules, in order:
    ///  1. meta unreadable/newer-schema                              -> .unusable
    ///  2. lockHeld                                                  -> .capturing   (live, whoever owns it)
    ///  3. meta.capture == .inProgress, or any spool exists, or a track with firstSample but no final audio -> .needsFinalize
    ///     (lock is free, so whatever was capturing is dead: interrupted, or stopped with the encode deferred)
    ///  4. no final audio for any track                              -> .unusable("no audio")
    ///  5. segmentsDecodes                                           -> .transcribed
    ///  6. otherwise                                                 -> .readyToTranscribe
    /// "both spool and m4a exist" is .needsFinalize: the spool is deleted only after the m4a was renamed into place,
    /// so a surviving spool means the previous finalize did not finish; re-running it is idempotent.
    static func classify(_ inventory: FolderInventory) -> SessionState { fatalError("not implemented") }
}

public struct SessionListing: Sendable, Equatable, Identifiable {
    public var ref: SessionRef
    public var id: UUID { ref.id }
    public var company: String
    public var title: String?
    public var startedAt: Date
    public var durationSeconds: Double?     // SessionTimeline.duration, nil until finalized
    public var state: SessionState
}

// MARK: - SessionStore

/// Single owner of everything in a session folder except the audio files:
/// meta.json, segments.json, transcript.md (+ transcript.prev.md), folder creation, listing.
/// All writes are atomic (temp file in the same directory + rename). All reads validate at this boundary and
/// return domain types; no JSON or file URL leaks out except through `SessionFolder`.
public actor SessionStore {
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone
    public let root: URL
    public init(root: URL, now: @escaping @Sendable () -> Date = { Date() }, timeZone: @escaping @Sendable () -> TimeZone = { .current }) {
        self.root = root; self.now = now; self.timeZone = timeZone
    }

    /// Allocates the folder (FolderNamer + collision handling), writes the initial meta.json
    /// (`capture: .inProgress`, tracks[*].source set, no audio) atomically. Idempotency: the folder name is
    /// reserved with `createDirectory(withIntermediateDirectories: false)`; on EEXIST pick the next suffix.
    /// Takes the CaptureLease BEFORE writing meta.json (so a folder never looks dead while it is being set up) and returns it;
    /// the caller keeps it until the session is finalized, then calls `release()`.
    public func create(_ draft: SessionDraft, mic: TrackSource, remote: TrackSource, app: AppInfo) throws -> (ref: SessionRef, lease: CaptureLease) {
        fatalError("not implemented")
    }

    public func meta(of ref: SessionRef) throws -> SessionMeta { fatalError("not implemented") }

    /// Read-modify-write of meta.json inside the actor => no lost updates between the controller, finalize and recovery.
    /// Refuses to write a file whose schemaVersion is newer than the app supports.
    @discardableResult
    public func update(_ ref: SessionRef, _ mutate: @Sendable (inout SessionMeta) -> Void) throws -> SessionMeta {
        fatalError("not implemented")
    }

    public func list() throws -> [SessionListing] { [] }

    public func state(of ref: SessionRef) throws -> SessionState { fatalError("not implemented") }

    public func segments(of ref: SessionRef) throws -> SegmentsFile? { fatalError("not implemented") }

    /// Writes segments.json, then renders and writes transcript.md (existing transcript.md moves to transcript.prev.md first).
    /// The order matters: transcript.md is derived, so a crash between the two leaves a stale-but-valid state
    /// that `rerender` (same function, same inputs) repairs.
    public func saveTranscription(_ ref: SessionRef, _ file: SegmentsFile) throws { fatalError("not implemented") }

    /// Re-renders transcript.md from the existing segments.json + meta.json with the current ReadingPolicy. No engine involved.
    /// Used by LaunchRecovery for `.transcribed` folders whose transcript.md is missing, and after a ReadingPolicy change.
    public func rerenderTranscript(_ ref: SessionRef) throws { fatalError("not implemented") }

    /// Deletes a folder that has no audio at all (start failed after `create`). Refuses otherwise.
    public func discardIfEmpty(_ ref: SessionRef) throws { fatalError("not implemented") }
}
