// <repo>/App/AppEnvironment.swift -- the composition root. NOT compiled in the sketch.
// This is the only file that knows every concrete type. Nothing below it imports it.
import Foundation
import AppKit
import OSLog
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

    func inputDevices() throws -> [InputDeviceInfo] { try LiveAudio.devices().inputDevices() }
    func microphoneLevels(device: InputDeviceInfo, channel: Int?) async throws -> AsyncThrowingStream<Float, any Error> {
        try await LiveAudio.microphoneLevels(device: device, channel: channel)
    }

    static func live() -> AppEnvironment {
        _ = AppDelegate.launchMode
        let settings = SettingsStore()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InterviewRecorder", isDirectory: true)
        let store = SessionStore(root: settings.settings.recordingsRoot ?? support.appendingPathComponent("Recordings"))
        let finalizer = SessionFinalizer(store: store, audio: LiveAudio.finalizer())
        let whisper = LiveWhisper.engine(base: support.appendingPathComponent("Models"), variant: settings.settings.modelVariant)
        let transcription = TranscriptionService(store: store, transcriber: whisper, models: whisper,
            language: { settings.settings.language })
        let devices = LiveAudio.devices()
        let readiness = ReadinessModel(probe: LiveAudio.permissions(), devices: devices,
            mic: { settings.settings.mic }, model: { transcription.model },
            requestedScreenBefore: settings.settings.screenCaptureRequested, relaunch: { Self.relaunch() })
        var hooks = RecordingController.Hooks()
        hooks.phaseChanged = { transcription.setRecordingActive($0.isCapturing) }
        hooks.sessionFinalized = { transcription.enqueue($0) }
        let app = AppInfo(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            os: ProcessInfo.processInfo.operatingSystemVersionString)
        let recorder = RecordingController(.init(store: store, backend: LiveAudio.backend(), devices: devices,
            finalizer: finalizer, app: app), readiness: { readiness.readiness }, mic: { settings.settings.mic }, hooks: hooks)
        let launched = Task {
            do { _ = try await LaunchRecovery.run(store: store, finalizer: finalizer) }
            catch { Logger(subsystem: "as.ason.InterviewRecorder", category: "launch").error("Launch recovery could not list sessions") }
            await readiness.refresh()
        }
        return AppEnvironment(settings: settings, store: store, readiness: readiness,
            recorder: recorder, transcription: transcription, launched: launched)
    }

    private init(settings: SettingsStore, store: SessionStore, readiness: ReadinessModel,
                 recorder: RecordingController, transcription: TranscriptionService, launched: Task<Void, Never>) {
        self.settings = settings; self.store = store; self.readiness = readiness
        self.recorder = recorder; self.transcription = transcription; self.launched = launched
    }
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
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath, "--args", LaunchMode.relaunchFlag]
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return }
            NSApp.terminate(nil)
        } catch {
            Logger(subsystem: "as.ason.InterviewRecorder", category: "launch").error("Relaunch failed: \(error)")
        }
    }
}
