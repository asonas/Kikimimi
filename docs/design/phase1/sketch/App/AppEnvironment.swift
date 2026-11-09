// <repo>/App/AppEnvironment.swift -- the composition root. NOT compiled in the sketch.
// This is the only file that knows every concrete type. Nothing below it imports it.
import Foundation
import Observation
import RecorderAudio
import RecorderCore
import RecorderWhisper

@MainActor @Observable
final class AppEnvironment {
    let settings: SettingsStore
    let store: SessionStore
    let readiness: ReadinessModel
    let recorder: RecordingController
    let transcription: TranscriptionService
    /// Launch recovery plus the first readiness refresh. The UI does not wait for it; the headless runner does.
    let launched: Task<Void, Never>

    /// Derived, never stored.
    var status: AppStatus { AppStatus.derive(phase: recorder.phase, jobs: transcription.jobs, readiness: readiness.readiness) }

    static func live() -> AppEnvironment { fatalError("not implemented") }
    // live() pseudocode:
    //   settings   = SettingsStore()
    //   root       = settings.recordingsRoot ?? ~/Library/Application Support/InterviewRecorder/Recordings
    //   store      = SessionStore(root:)
    //   finalizer  = SessionFinalizer(store: store, audio: LiveAudio.finalizer())
    //   whisper    = LiveWhisper.engine(base: .../Models, variant: settings.modelVariant)     // one object, both ports
    //   transcription = TranscriptionService(store:, transcriber: whisper, models: whisper, language: { settings.language })
    //   readiness  = ReadinessModel(probe: LiveAudio.permissions(), devices: LiveAudio.devices(), mic: { settings.mic }, model: { transcription.model },
    //                  requestedScreenBefore: settings.screenCaptureRequested, relaunch: { Self.relaunch() })
    //   recorder   = RecordingController(.init(store:, backend: LiveAudio.backend(), devices:, finalizer:, app:), readiness: { readiness.readiness }, mic: { settings.mic },
    //                  hooks: { phaseChanged: { transcription.setRecordingActive($0.isCapturing) }, sessionFinalized: { transcription.enqueue($0) } })
    //   launched   = Task { let recovered = (try? await LaunchRecovery.run(store:, finalizer:)) ?? []; await readiness.refresh(); /* notice only; never auto-transcribe */ }
    //                (the headless runner awaits `launched` before acting)

    /// Through LaunchServices, never by exec'ing our own binary: TCC attributes a LaunchServices launch to the app itself.
    /// Process(/usr/bin/open, ["-n", Bundle.main.bundlePath, "--args", LaunchMode.relaunchFlag]).run(); then NSApp.terminate(nil).
    /// `--relaunch` makes the new instance skip the single-instance nicety while this one is still exiting.
    static func relaunch() { fatalError("not implemented") }
}
