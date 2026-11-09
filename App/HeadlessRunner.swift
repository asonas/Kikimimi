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
        await env.launched.value
        do {
            switch command {
            case let .record(draft, seconds):
                guard env.readiness.readiness.canRecord else {
                    return fail(String(describing: StartError.notReady(env.readiness.readiness.blockers)))
                }
                try await env.recorder.start(draft)
                guard case .recording(let recording) = env.recorder.phase else { return fail("capture did not start") }
                log("Recording id=\(recording.ref.id) folder=\(recording.ref.folder.url.path)")
                let deadline = ProcessInfo.processInfo.systemUptime + seconds
                do {
                    while ProcessInfo.processInfo.systemUptime < deadline {
                        let remaining = deadline - ProcessInfo.processInfo.systemUptime
                        try await Task.sleep(for: .seconds(max(0, min(1, remaining))))
                        log("Capture: \(env.recorder.phase)")
                    }
                } catch {
                    await env.recorder.stopForQuit()
                    throw error
                }
                await env.recorder.stop()
                let state = try await env.store.state(of: recording.ref)
                let meta = try await env.store.meta(of: recording.ref)
                for (track, value) in meta.tracks.present {
                    log("\(track.rawValue): audio=\(String(describing: value.audio)) failure=\(String(describing: value.failure))")
                }
                guard state == .readyToTranscribe || state == .transcribed else { return fail("capture ended in \(state)") }
                return succeed("record id=\(recording.ref.id) folder=\(recording.ref.folder.url.path) state=\(state)")
            case .transcribe(let id):
                guard let ref = try await env.store.list().first(where: { $0.id == id })?.ref else {
                    return fail("unknown session")
                }
                env.transcription.enqueue(ref)
                guard env.transcription.jobs.contains(where: { $0.id == id }) else {
                    return fail("transcription service is not implemented yet")
                }
                var previous: TranscriptionJobState?
                while let job = env.transcription.jobs.first(where: { $0.id == id }) {
                    if job.state != previous { log("Transcription: \(job.state)"); previous = job.state }
                    switch job.state {
                    case .done:
                        let segments = try await env.store.segments(of: ref)
                        for track in Track.allCases {
                            log("\(track.rawValue): \(segments?.segments.filter { $0.speaker == track }.count ?? 0) segments")
                        }
                        return succeed("transcribe segments=\(ref.folder.segments.path) transcript=\(ref.folder.transcript.path)")
                    case .failed(let message): return fail(message)
                    default: try await Task.sleep(for: .milliseconds(500))
                    }
                }
                return fail("transcription job disappeared")
            }
        } catch { return fail(String(describing: error)) }
    }

    private static func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    private static func fail(_ message: String) -> Never { log("HEADLESS FAILED: \(message)"); exit(2) }
    private static func succeed(_ message: String) -> Never { log("HEADLESS OK \(message)"); exit(0) }
}
#endif
