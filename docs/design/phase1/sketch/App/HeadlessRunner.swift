// <repo>/App/HeadlessRunner.swift -- DEBUG builds only. NOT compiled in the sketch.
// A second caller of the same controller methods the UI uses, so a coding agent can verify recording and transcription
// end to end without clicking the menu bar. Parsing is pure and tested in Core (LaunchMode / HeadlessCommand).
//
// Always launched through LaunchServices:  mise run app --headless ...   (= open -n -W --stdout .. --stderr .. <app> --args --headless ...)
// Never run build/.../InterviewRecorder.app/Contents/MacOS/InterviewRecorder directly: the terminal (Herdr, Ghostty) has its
// own Screen Recording grant, so a directly started binary would pass or fail on the terminal's TCC state, not the app's.
#if DEBUG
import AppKit
import Foundation
import RecorderCore

@MainActor
enum HeadlessRunner {
    /// Prints one line per step to stderr and ends with exactly one of
    ///   HEADLESS OK <details>
    ///   HEADLESS FAILED: <reason>
    /// then exits. `open -W` does not propagate the exit status, so the last log line IS the result.
    ///
    /// record(draft, seconds):
    ///   await env.launched                       // LaunchRecovery and the first readiness refresh have finished
    ///   if !env.readiness.readiness.canRecord -> FAILED with the blockers. NEVER call requestScreenCapture() here:
    ///                                            requesting and then exiting is what made TCC record a denial in Phase 0.
    ///   try await env.recorder.start(draft)      // the Start button's call; StartError -> FAILED: <error>
    ///   sleep(seconds); print per-track health from env.recorder.phase once per second
    ///   await env.recorder.stop()                // the Stop button's call; returns after finalize
    ///   print folder path, meta.id, SessionState (expect .readyToTranscribe), meta.tracks[*].audio and failures -> OK
    ///   Does not wait for the transcription the stop hook enqueued; exiting cancels it and nothing partial is written.
    ///
    /// transcribe(sessionID):
    ///   await env.launched
    ///   ref = try await env.store.list().first { $0.id == sessionID }?.ref   else FAILED: unknown session
    ///   env.transcription.enqueue(ref)           // the Re-transcribe button's call; synchronous, job is now queued/waiting
    ///   poll env.transcription.jobs every 0.5 s until the job is .done or .failed (print .waiting reasons as they change)
    ///   .done -> print segments.json/transcript.md paths and segment counts per track -> OK;  .failed(msg) -> FAILED: msg
    static func run(_ command: HeadlessCommand, env: AppEnvironment) async -> Never {
        fatalError("not implemented")
    }
}
#endif
