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
    let modelVariant: String
    let modelVariantOverridden: Bool
    let termination = TerminationCoordinator()
    let calendar = CalendarModel(source: LiveCalendar())
    let summaryCredentials = SummaryCredentials()
    /// Launch recovery plus the first readiness refresh. The UI does not wait for it; the headless runner does.
    let launched: Task<Void, Never>

    /// Derived, never stored.
    var status: AppStatus { AppStatus.derive(phase: recorder.phase, jobs: transcription.jobs, readiness: readiness.readiness) }

    func inputDevices() throws -> [InputDeviceInfo] { try LiveAudio.devices().inputDevices() }
    func remoteCandidates() async throws -> [RemoteSource] { try await LiveAudio.backend().runningRemoteCandidates() }
    func microphoneLevels(device: InputDeviceInfo, channel: Int?) async throws -> AsyncThrowingStream<Float, any Error> {
        try await LiveAudio.microphoneLevels(device: device, channel: channel)
    }

    static func live() -> AppEnvironment {
        let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let support = parent.appendingPathComponent("Kikimimi", isDirectory: true)
        let logger = Logger(subsystem: "as.ason.Kikimimi", category: "migration")
        do {
            let outcome = try LegacyInstallMigration.moveFolder(
                old: parent.appendingPathComponent(LegacyInstallMigration.folderName), new: support)
            logger.info("Legacy folder migration: \(outcome.rawValue, privacy: .public)")
        } catch {
            logger.error("Legacy folder migration failed: \(error)")
        }
        if let oldDefaults = UserDefaults(suiteName: LegacyInstallMigration.defaultsDomain) {
            let copied = LegacyInstallMigration.copySettings(old: oldDefaults, new: .standard)
            logger.info("Legacy settings copied: \(copied)")
        }
        _ = AppDelegate.launchMode
        let settings = SettingsStore()
        let store = SessionStore(root: settings.settings.recordingsRoot ?? support.appendingPathComponent("Recordings"))
        let finalizer = SessionFinalizer(store: store, audio: LiveAudio.finalizer())
        #if DEBUG
        let value = ProcessInfo.processInfo.environment["IR_MODEL_VARIANT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = value.flatMap { $0.isEmpty ? nil : $0 }
        #else
        let override: String? = nil
        #endif
        let variant = override ?? settings.settings.modelVariant
        #if DEBUG
        FileHandle.standardError.write(Data("MODEL variant=\(variant) override=\(override != nil)\n".utf8))
        #endif
        let whisper = LiveWhisper.engine(base: support.appendingPathComponent("Models"), variant: variant)
        let transcription = TranscriptionService(store: store, transcriber: whisper, models: whisper,
            language: { settings.settings.language })
        let devices = LiveAudio.devices()
        let readiness = ReadinessModel(probe: LiveAudio.permissions(), devices: devices,
            mic: { settings.settings.mic }, model: { transcription.model },
            requestedScreenBefore: settings.settings.screenCaptureRequested, relaunch: { Self.relaunch() })
        let hooks = RecordingController.Hooks.transcribing(with: transcription)
        let app = AppInfo(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            os: ProcessInfo.processInfo.operatingSystemVersionString)
        let recorder = RecordingController(.init(store: store, backend: LiveAudio.backend(), devices: devices,
            finalizer: finalizer, app: app), readiness: { readiness.readiness }, mic: { settings.settings.mic }, hooks: hooks)
        let launched = Task {
            do { _ = try await LaunchRecovery.run(store: store, finalizer: finalizer) }
            catch { Logger(subsystem: "as.ason.Kikimimi", category: "launch").error("Launch recovery could not list sessions") }
            await readiness.refresh()
        }
        return AppEnvironment(settings: settings, store: store, readiness: readiness,
            recorder: recorder, transcription: transcription, launched: launched,
            modelVariant: variant, modelVariantOverridden: override != nil)
    }

    private init(settings: SettingsStore, store: SessionStore, readiness: ReadinessModel,
                 recorder: RecordingController, transcription: TranscriptionService, launched: Task<Void, Never>,
                 modelVariant: String, modelVariantOverridden: Bool) {
        self.settings = settings; self.store = store; self.readiness = readiness
        self.recorder = recorder; self.transcription = transcription; self.launched = launched
        self.modelVariant = modelVariant; self.modelVariantOverridden = modelVariantOverridden
    }
    // live() pseudocode:
    //   settings   = SettingsStore()
    //   root       = settings.recordingsRoot ?? ~/Library/Application Support/Kikimimi/Recordings
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
            Logger(subsystem: "as.ason.Kikimimi", category: "launch").error("Relaunch failed: \(error)")
        }
    }
}
