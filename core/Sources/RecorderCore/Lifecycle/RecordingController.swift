import Foundation
import Observation

public enum StartError: Error, Sendable, Equatable {
    case notReady([ReadinessBlocker])        // permissions / mic not chosen: onboarding is the fix
    case micMissing(MicPreference)           // chosen device is not connected
    case micChannelOutOfRange(device: String, requested: Int, available: Int)
    case remoteAppNotRunning(name: String)
    case companyEmpty
    case alreadyActive
    case insufficientDisk(availableGB: Double)   // spool is ~0.35 GB/h/track while recording; require >= 5 GB free
    case storage(String)
    case captureFailed(String)               // SCStream/AVAudioEngine refused to start
}

/// Owns RecordingPhase. The UI reads `phase`, `levels`; it calls `start` and `stop`. Nothing else mutates them.
///
/// Call chain for the whole feature: UI -> RecordingController.start -> {Readiness, MicResolution, SessionStore.create,
/// CaptureBackend.start}; events -> phase reducer -> effects; stop -> CaptureBackend.stop -> SessionFinalizer.run.
/// Three files: this one, RecordingPhase.swift (pure policy), SessionFinalizer.swift (shared with recovery).
@MainActor @Observable
public final class RecordingController {
    private let deps: Dependencies
    private let readiness: @MainActor () -> Readiness
    private let mic: @MainActor () -> MicPreference?
    private let hooks: Hooks
    public private(set) var phase: RecordingPhase = .idle
    /// Latest peak per track for the meter. nil when not recording.
    public private(set) var levels: TrackPair<Float>?

    public struct Dependencies: Sendable {
        public var store: SessionStore
        public var backend: any CaptureBackend
        public var devices: any InputDeviceCatalog
        public var finalizer: SessionFinalizer
        public var app: AppInfo
        public var now: @Sendable () -> Date
        public init(store: SessionStore, backend: any CaptureBackend, devices: any InputDeviceCatalog,
                    finalizer: SessionFinalizer, app: AppInfo, now: @escaping @Sendable () -> Date = { Date() }) {
            self.store = store; self.backend = backend; self.devices = devices
            self.finalizer = finalizer; self.app = app; self.now = now
        }
    }

    /// Wired in the composition root: `{ queue.setRecordingActive($0.isCapturing) }`, `{ queue.enqueue($0) }`.
    public struct Hooks {
        public var phaseChanged: (RecordingPhase) -> Void = { _ in }
        public var sessionFinalized: (SessionRef) -> Void = { _ in }
        public init() {}
    }

    public init(_ deps: Dependencies, readiness: @escaping @MainActor () -> Readiness,
                mic: @escaping @MainActor () -> MicPreference?, hooks: Hooks = Hooks()) {
        self.deps = deps; self.readiness = readiness; self.mic = mic; self.hooks = hooks
    }

    /// Validates (throws StartError, creates nothing on failure before step 4):
    ///  1. phase == .idle                                   -> else .alreadyActive
    ///  2. readiness().blockers.isEmpty                      -> else .notReady
    ///  3. MicResolution.resolve(mic(), devices)             -> .micMissing / .micChannelOutOfRange (NEVER default-mic fallback)
    ///     + remote app is in backend.runningRemoteCandidates(), matched by bundleID only (the candidate's display name
    ///       is what meta.json records)                      -> else .remoteAppNotRunning
    ///  3b. free disk >= 5 GB (spool ~0.7 GB/h for both tracks) -> else .insufficientDisk
    ///  4. store.create(...) -> (ref, lease)                 (folder + CaptureLease + initial meta, capture: .inProgress);
    ///                                                       the lease is held in a private property until finalize completes or quit
    ///  5. backend.start(plan)                               on throw: store.discardIfEmpty, release lease, phase -> idle, rethrow as .captureFailed
    ///  6. send(.prepared); start consuming RunningCapture.events: .level and .digitalSilence go through SilenceMonitor
    ///     (the one owner of non-failure TrackHealth) and become .trackHealthChanged; .trackFailed is persisted, then sent
    ///
    /// The DEBUG headless runner (App/HeadlessRunner.swift) calls exactly `start` and `stop`, like the Start/Stop buttons.
    public func start(_ draft: SessionDraft) async throws(StartError) { fatalError("not implemented") }

    /// User stop. Returns when the phase is back to .idle (finalize included).
    public func stop() async { fatalError("not implemented") }

    /// App quit. Handles every phase so `applicationShouldTerminate` can always reply:
    /// idle -> returns at once; preparing -> awaits the in-flight `start` (it ends in recording or idle), then continues as
    /// recording; recording -> stop capture, close spools, write endedAt(.quit), release the lease, skip the AAC encode;
    /// stopping -> awaits it. The next launch's recovery finalizes with the same code path. Bounded work: well under a second
    /// (the caller also applies a 10 s timeout and replies regardless).
    public func stopForQuit() async { fatalError("not implemented") }

    // send(event): let t = phase.applying(event); if t.kind == .illegal -> log + return; phase = t.phase;
    // hooks.phaseChanged(phase); for e in t.effects { await perform(e) }
}
