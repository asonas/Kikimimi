import Foundation

/// THE one path from "capture ended (cleanly or not)" to "final m4a files + finished meta".
/// Used by RecordingController.stop and by launch-time recovery. Idempotent by construction: every step is guarded by
/// what exists on disk, so running it again after a crash at any point converges to the same result.
public struct SessionFinalizer: Sendable {
    let store: SessionStore
    let audio: any AudioFinalizer
    public init(store: SessionStore, audio: any AudioFinalizer) { self.store = store; self.audio = audio }

    /// Steps (pseudocode):
    ///  1. meta = store.meta(ref)
    ///  2. facts = audio.finalize(folder)   // per track, decided only by which files exist:
    ///                                      //   .m4a exists            => complete BY CONSTRUCTION (it is renamed into place only after the
    ///                                      //                             encode was verified). Delete a leftover spool; read facts from the m4a.
    ///                                      //   spool only             => truncate to whole frames, encode to .m4a.part, verify decodable and
    ///                                      //                             |frames - spool frames| <= 2048 (AAC priming), rename .part -> .m4a, THEN delete spool.
    ///                                      //   .part only / .part+spool => stale partial: delete .part, treat as "spool only".
    ///                                      //   neither                => track absent.
    ///                                      // Crash points: during encode (.part+spool) / after rename (m4a+spool) / after delete (m4a) all converge.
    ///  3. store.update(ref) { meta in
    ///        meta.tracks[t].audio = facts.tracks[t]                     // derived, overwritten every run
    ///        if meta.capture == .inProgress { meta.capture = .finished(endedAt: estimate, reason: .recovered) }
    ///        else if reason given && still .inProgress... (live stop passes its own reason and endedAt = now)
    ///        tracks with no audio ever and no failure => failure = .noAudioEver
    ///     }
    ///  4. if no track has audio => throws FinalizeError.nothingRecorded (caller: store.discardIfEmpty)
    ///  endedAt estimate for a crashed session = startedAt + max track (offset + duration); live stop uses `now`.
    public func run(_ ref: SessionRef, reason: EndReason, clockDiagnostics: PerTrack<ClockDiagnostics> = .init(),
                    endedAt: Date? = nil) async throws {
        _ = try await store.meta(of: ref)
        let facts: FinalizedAudio
        do { facts = try await audio.finalize(ref.folder, clockTolerance: 0.1) }
        catch { throw FinalizeError.encodeFailed(String(describing: error)) }
        let updated = try await store.update(ref) { meta in
            for (track, _) in meta.tracks.present {
                meta.tracks[track]?.audio = facts.tracks[track]
                meta.tracks[track]?.diagnostics = clockDiagnostics[track]
                if facts.tracks[track] == nil, meta.tracks[track]?.failure == nil {
                    meta.tracks[track]?.failure = .init(code: .noAudioEver, message: "No audio was recorded")
                }
            }
            if meta.capture == .inProgress {
                let end = endedAt ?? meta.startedAt.addingTimeInterval(SessionTimeline.duration(of: meta))
                meta.capture = .finished(endedAt: end, reason: reason)
            }
        }
        guard updated.tracks.present.contains(where: { $0.1.audio != nil }) else { throw FinalizeError.nothingRecorded }
    }
}

public enum FinalizeError: Error, Sendable, Equatable { case nothingRecorded, encodeFailed(String) }

/// Launch-time recovery. Runs once, before the UI offers Start. Never transcribes (crash-loop guard: a model that
/// crashes the app must not be re-run automatically on every launch); it only makes audio safe and visible.
public enum LaunchRecovery {
    /// For each listing in state .needsFinalize (lock free AND unfinished) -> take the CaptureLease for the duration, then
    /// SessionFinalizer.run(reason: .recovered). `.capturing` (lock held by any process, including a second app instance
    /// or an Xcode Debug run) is NEVER touched. Folders with no audio at all and a free lock are removed (nothing to lose).
    /// `.transcribed` folders whose transcript.md is missing are re-rendered (no engine). `.unusable` folders are left
    /// untouched and reported. Returns the sessions recovered, for a one-time "前回の録音を回復しました" notice.
    /// Correctness does not depend on single-instance enforcement.
    public static func run(store: SessionStore, finalizer: SessionFinalizer) async throws -> [SessionRef] {
        var recovered: [SessionRef] = []
        for listing in try await store.list() {
            guard listing.state == .needsFinalize,
                  let lease = CaptureLease.acquire(listing.ref.folder.lock) else { continue }
            defer { lease.release() }
            do {
                try await finalizer.run(listing.ref, reason: .recovered)
                recovered.append(listing.ref)
            } catch FinalizeError.nothingRecorded {
                // discardIfEmpty independently refuses every remaining audio artifact.
                do { try await store.discardIfEmpty(listing.ref) }
                catch { logFailure() }
            } catch { logFailure() }
        }
        return recovered
    }

    private static func logFailure() {
        FileHandle.standardError.write(Data("Session recovery failed; preserved for a later retry\n".utf8))
    }
}
