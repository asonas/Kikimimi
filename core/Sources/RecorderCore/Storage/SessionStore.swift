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
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var companyPart = ""
        var inWhitespace = false
        for character in company.precomposedStringWithCanonicalMapping {
            // Cc controls are forbidden; format scalars such as emoji ZWJ must survive.
            if character.unicodeScalars.contains(where: { forbidden.contains($0) || $0.properties.generalCategory == .control }) {
                companyPart.append("-"); inWhitespace = false
            } else if character.isWhitespace {
                if !inWhitespace { companyPart.append("_") }
                inWhitespace = true
            } else {
                companyPart.append(character); inWhitespace = false
            }
        }
        let edges = CharacterSet(charactersIn: "-_.")
        companyPart = String(companyPart.trimmingCharacters(in: edges).prefix(40))
            .trimmingCharacters(in: edges)
        if companyPart.isEmpty { companyPart = "untitled" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let base = formatter.string(from: startedAt) + "_" + companyPart
        let occupied = Set(taken.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        var candidate = base
        var suffix = 2
        while occupied.contains(candidate.lowercased()) {
            candidate = base + "-\(suffix)"; suffix += 1
        }
        return candidate
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
    static func classify(_ inventory: FolderInventory) -> SessionState {
        let meta: SessionMeta
        switch inventory.meta {
        case .success(let value):
            guard value.schemaVersion <= SessionMeta.currentSchemaVersion else {
                return .unusable("newer schema: \(value.schemaVersion)")
            }
            meta = value
        case .failure(let problem): return .unusable(String(describing: problem))
        }
        if inventory.lockHeld { return .capturing }
        if meta.capture == .inProgress
            || inventory.spoolExists.present.contains(where: { $0.1 })
            || meta.tracks.present.contains(where: {
                $0.1.firstSampleHostSeconds != nil && inventory.finalAudioExists[$0.0] != true
            }) {
            return .needsFinalize
        }
        guard inventory.finalAudioExists.present.contains(where: { $0.1 }) else { return .unusable("no audio") }
        return inventory.segmentsDecodes ? .transcribed : .readyToTranscribe
    }
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
    private let atomicWrite: @Sendable (Data, URL) throws -> Void
    public let root: URL
    public init(root: URL, now: @escaping @Sendable () -> Date = { Date() }, timeZone: @escaping @Sendable () -> TimeZone = { .current }) {
        self.init(root: root, now: now, timeZone: timeZone, atomicWrite: { try $0.write(to: $1, options: .atomic) })
    }

    init(root: URL, now: @escaping @Sendable () -> Date = { Date() }, timeZone: @escaping @Sendable () -> TimeZone = { .current },
         atomicWrite: @escaping @Sendable (Data, URL) throws -> Void) {
        self.root = root; self.now = now; self.timeZone = timeZone
        self.atomicWrite = atomicWrite
    }

    /// Allocates the folder (FolderNamer + collision handling), writes the initial meta.json
    /// (`capture: .inProgress`, tracks[*].source set, no audio) atomically. Idempotency: the folder name is
    /// reserved with `createDirectory(withIntermediateDirectories: false)`; on EEXIST pick the next suffix.
    /// Takes the CaptureLease BEFORE writing meta.json (so a folder never looks dead while it is being set up) and returns it;
    /// the caller keeps it until the session is finalized, then calls `release()`.
    public func create(_ draft: SessionDraft, mic: TrackSource, remote: TrackSource, app: AppInfo) throws -> (ref: SessionRef, lease: CaptureLease) {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let startedAt = Date(timeIntervalSince1970: floor(now().timeIntervalSince1970))
        let zone = timeZone()
        var taken = Set(try manager.contentsOfDirectory(atPath: root.path))
        while true {
            let name = FolderNamer.name(company: draft.company, startedAt: startedAt, timeZone: zone, taken: taken)
            let folder = SessionFolder(url: root.appendingPathComponent(name, isDirectory: true))
            // FileManager accepts an existing directory; mkdir reserves the name exclusively.
            guard mkdir(folder.url.path, 0o755) == 0 else {
                if errno == EEXIST {
                    taken.formUnion(try manager.contentsOfDirectory(atPath: root.path))
                    taken.insert(name)
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            do {
                guard let lease = CaptureLease.acquire(folder.lock) else { throw CocoaError(.fileWriteUnknown) }
                let meta = SessionMeta(id: UUID(), company: draft.company, title: draft.title,
                                       timeZone: zone.identifier, startedAt: startedAt, app: app,
                                       tracks: .init(me: .init(source: mic), remote: .init(source: remote)), event: draft.event)
                try writeMeta(meta, to: folder)
                return (SessionRef(id: meta.id, folder: folder), lease)
            } catch {
                try? manager.removeItem(at: folder.url)
                throw error
            }
        }
    }

    public func meta(of ref: SessionRef) throws -> SessionMeta {
        try decoder().decode(SessionMeta.self, from: Data(contentsOf: ref.folder.meta))
    }

    /// Read-modify-write of meta.json inside the actor => no lost updates between the controller, finalize and recovery.
    /// Refuses to write a file whose schemaVersion is newer than the app supports.
    @discardableResult
    public func update(_ ref: SessionRef, _ mutate: @Sendable (inout SessionMeta) -> Void) throws -> SessionMeta {
        var value = try meta(of: ref)
        mutate(&value)
        try writeMeta(value, to: ref.folder)
        return value
    }

    public func list() throws -> [SessionListing] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        let folders = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var listings: [SessionListing] = []
        for url in folders {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let folder = SessionFolder(url: url)
            guard let value = try? decoder().decode(SessionMeta.self, from: Data(contentsOf: folder.meta)) else { continue }
            let ref = SessionRef(id: value.id, folder: folder)
            let hasAudio = value.tracks.present.contains { $0.1.audio != nil }
            listings.append(SessionListing(ref: ref, company: value.company, title: value.title,
                                           startedAt: value.startedAt,
                                           durationSeconds: hasAudio ? SessionTimeline.duration(of: value) : nil,
                                           state: try state(of: ref)))
        }
        return listings.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.ref.folder.url.path < $1.ref.folder.url.path
        }
    }

    public func state(of ref: SessionRef) throws -> SessionState {
        let result: Result<SessionMeta, InventoryProblem>
        do { result = .success(try meta(of: ref)) }
        catch SessionMetaError.newerThanSupported(let found, _) { result = .failure(.newerSchema(found)) }
        catch {
            result = .failure(FileManager.default.fileExists(atPath: ref.folder.meta.path)
                ? .undecodable(String(describing: error)) : .missing)
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        return SessionClassifier.classify(.init(
            meta: result, lockHeld: CaptureLease.isHeld(ref.folder.lock),
            spoolExists: .init(me: exists(ref.folder.spool(.me)), remote: exists(ref.folder.spool(.remote))),
            finalAudioExists: .init(me: exists(ref.folder.audio(.me)), remote: exists(ref.folder.audio(.remote))),
            segmentsDecodes: (try? segments(of: ref)) != nil))
    }

    public func segments(of ref: SessionRef) throws -> SegmentsFile? {
        guard FileManager.default.fileExists(atPath: ref.folder.segments.path) else { return nil }
        let file = try decoder().decode(SegmentsFile.self, from: Data(contentsOf: ref.folder.segments))
        guard file.schemaVersion <= SegmentsFile.currentSchemaVersion else { throw CocoaError(.fileReadCorruptFile) }
        return file
    }

    /// Read-only presentation of segments using the same filtering/coalescing policy as Markdown.
    /// nil means no segments file; malformed or unsupported files throw. Never parses or rewrites Markdown.
    public func transcriptLines(of ref: SessionRef) throws -> [TranscriptLine]? {
        try segments(of: ref).map { TranscriptReader.lines(from: $0.segments) }
    }

    /// Writes segments.json, then renders and writes transcript.md (existing transcript.md moves to transcript.prev.md first).
    /// The order matters: transcript.md is derived, so a crash between the two leaves a stale-but-valid state
    /// that `rerender` (same function, same inputs) repairs.
    public func saveTranscription(_ ref: SessionRef, _ file: SegmentsFile) throws {
        let meta = try writableMeta(ref)
        guard file.schemaVersion <= SegmentsFile.currentSchemaVersion else { throw CocoaError(.fileReadCorruptFile) }
        try refuseNewerSegments(ref)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let segments = try encoder.encode(file)
        let markdown = Data(TranscriptRenderer.render(meta: meta, segments: file).utf8)
        let previous = FileManager.default.fileExists(atPath: ref.folder.transcript.path)
            ? try Data(contentsOf: ref.folder.transcript) : nil
        try Task.checkCancellation()
        // Once this synchronous commit begins, finish even if capture starts concurrently.
        try atomicWrite(segments, ref.folder.segments)
        if let previous { try atomicWrite(previous, ref.folder.transcriptBackup) }
        try atomicWrite(markdown, ref.folder.transcript)
    }

    /// Re-renders transcript.md from the existing segments.json + meta.json with the current ReadingPolicy. No engine involved.
    /// Used by LaunchRecovery for `.transcribed` folders whose transcript.md is missing, and after a ReadingPolicy change.
    public func rerenderTranscript(_ ref: SessionRef) throws {
        let meta = try writableMeta(ref)
        guard let file = try segments(of: ref) else { throw CocoaError(.fileNoSuchFile) }
        let markdown = Data(TranscriptRenderer.render(meta: meta, segments: file).utf8)
        try Task.checkCancellation()
        try atomicWrite(markdown, ref.folder.transcript)
    }

    private func writableMeta(_ ref: SessionRef) throws -> SessionMeta {
        guard !CaptureLease.isHeld(ref.folder.lock) else { throw CocoaError(.fileWriteNoPermission) }
        return try meta(of: ref)
    }

    /// Only complete summaries reach this method; preserve one previous result before atomic replacement.
    public func saveSummary(_ ref: SessionRef, markdown: String) throws {
        _ = try writableMeta(ref)
        let previous = FileManager.default.fileExists(atPath: ref.folder.summary.path)
            ? try Data(contentsOf: ref.folder.summary) : nil
        try Task.checkCancellation()
        if let previous { try atomicWrite(previous, ref.folder.summaryBackup) }
        try atomicWrite(Data(markdown.utf8), ref.folder.summary)
    }

    private func refuseNewerSegments(_ ref: SessionRef) throws {
        struct Header: Decodable { let schemaVersion: Int }
        guard FileManager.default.fileExists(atPath: ref.folder.segments.path) else { return }
        let data = try Data(contentsOf: ref.folder.segments)
        if let header = try? JSONDecoder().decode(Header.self, from: data), header.schemaVersion > SegmentsFile.currentSchemaVersion {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    /// Deletes a folder that has no audio at all (start failed after `create`). Refuses otherwise.
    public func discardIfEmpty(_ ref: SessionRef) throws {
        _ = try meta(of: ref)
        let hasAudio = Track.allCases.contains { track in
            [ref.folder.spool(track), ref.folder.audio(track), ref.folder.audioPart(track)]
                .contains { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard !hasAudio else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: ref.folder.url)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func writeMeta(_ meta: SessionMeta, to folder: SessionFolder) throws {
        guard meta.schemaVersion <= SessionMeta.currentSchemaVersion else {
            throw SessionMetaError.newerThanSupported(found: meta.schemaVersion, supported: SessionMeta.currentSchemaVersion)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: folder.meta, options: .atomic)
    }
}
