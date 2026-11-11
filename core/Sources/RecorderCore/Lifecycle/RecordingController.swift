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
    /// Coalesced display samples; independent of the one-second health input above.
    public private(set) var meterLevels: TrackPair<MeterSample?>?
    @ObservationIgnored private var pendingMeter = TrackPair<MeterSample?>(both: nil)
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    private var running: (any RunningCapture)?
    private var lease: CaptureLease?
    private var eventTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var monitor = SilenceMonitor()
    private var phaseWaiters: [CheckedContinuation<Void, Never>] = []

    public struct Dependencies: Sendable {
        public var store: SessionStore
        public var backend: any CaptureBackend
        public var devices: any InputDeviceCatalog
        public var finalizer: SessionFinalizer
        public var app: AppInfo
        public var now: @Sendable () -> Date
        public var availableDiskBytes: @Sendable (URL) throws -> Int64
        public init(store: SessionStore, backend: any CaptureBackend, devices: any InputDeviceCatalog,
                    finalizer: SessionFinalizer, app: AppInfo, now: @escaping @Sendable () -> Date = { Date() },
                    availableDiskBytes: @escaping @Sendable (URL) throws -> Int64 = { url in
                        var existing = url
                        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
                            existing.deleteLastPathComponent()
                        }
                        let values = try existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                        guard let bytes = values.volumeAvailableCapacityForImportantUsage else { throw CocoaError(.fileReadUnknown) }
                        return bytes
                    }) {
            self.store = store; self.backend = backend; self.devices = devices
            self.finalizer = finalizer; self.app = app; self.now = now
            self.availableDiskBytes = availableDiskBytes
        }
    }

    /// Wired in the composition root: `{ queue.setRecordingActive($0.isCapturing) }`, `{ queue.enqueue($0) }`.
    public struct Hooks {
        public var phaseChanged: (RecordingPhase) -> Void = { _ in }
        public var sessionFinalized: (SessionRef) -> Void = { _ in }
        public init() {}

        @MainActor public static func transcribing(with service: TranscriptionService) -> Self {
            var hooks = Self()
            hooks.phaseChanged = { service.setRecordingActive($0.isCapturing) }
            hooks.sessionFinalized = { service.enqueue($0) }
            return hooks
        }
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
    public func start(_ draft: SessionDraft) async throws(StartError) {
        guard phase == .idle else { throw .alreadyActive }
        var draft = draft
        draft.company = draft.company.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.company.isEmpty else { throw .companyEmpty }
        _ = transition(.startRequested(draft))
        var created: SessionRef?
        do {
            let blockers = readiness().blockers
            guard blockers.isEmpty else { throw StartError.notReady(blockers) }
            let device: InputDeviceInfo, channel: Int?
            switch MicResolution.resolve(mic(), available: try deps.devices.inputDevices()) {
            case .use(let selected, let selectedChannel): device = selected; channel = selectedChannel
            case .notChosen: throw StartError.notReady([.micNotChosen])
            case .deviceMissing(let preference): throw StartError.micMissing(preference)
            case let .channelOutOfRange(selected, requested):
                throw StartError.micChannelOutOfRange(device: selected.name, requested: requested, available: selected.inputChannels)
            }
            if case .app(let id, let name) = draft.remote {
                let candidates = try await deps.backend.runningRemoteCandidates()
                guard let candidate = candidates.first(where: {
                    if case .app(let candidateID, _) = $0 { return candidateID == id }; return false
                }) else { throw StartError.remoteAppNotRunning(name: name) }
                draft.remote = candidate
            }
            let free = try deps.availableDiskBytes(deps.store.root)
            guard free >= 5_000_000_000 else { throw StartError.insufficientDisk(availableGB: Double(free) / 1_000_000_000) }
            let remote: TrackSource
            switch draft.remote {
            case .app(let id, let name): remote = .app(bundleID: id, name: name)
            case .allSystemAudio: remote = .allSystemAudio
            }
            let allocation = try await deps.store.create(draft,
                mic: .mic(deviceUID: device.uid, deviceName: device.name, channel: channel, deviceChannels: device.inputChannels),
                remote: remote, app: deps.app)
            created = allocation.ref; lease = allocation.lease
            let ref = allocation.ref, store = deps.store
            let plan = CapturePlan(folder: ref.folder, mic: (device, channel), remote: draft.remote) { track, host in
                try await store.update(ref) { $0.tracks[track]?.firstSampleHostSeconds = host }
            }
            let capture: any RunningCapture
            do { capture = try await deps.backend.start(plan) }
            catch { throw StartError.captureFailed(String(describing: error)) }
            running = capture
            monitor = SilenceMonitor(); levels = .init(both: -120)
            let startedAt = try await store.meta(of: ref).startedAt
            _ = transition(.prepared(ref, startedAt: startedAt))
            startMeterDisplay()
            eventTask = Task { [weak self] in
                for await event in capture.events { await self?.handle(event, ref: ref) }
            }
        } catch {
            if let running { _ = await running.stop(); self.running = nil }
            if let created { try? await deps.store.discardIfEmpty(created) }
            lease?.release(); lease = nil; levels = nil; clearMeterDisplay()
            _ = transition(.prepareFailed)
            if let error = error as? StartError { throw error }
            throw .storage(String(describing: error))
        }
    }

    /// User stop. Returns when the phase is back to .idle (finalize included).
    public func stop() async { await stop(reason: .user) }

    /// App quit. Handles every phase so `applicationShouldTerminate` can always reply:
    /// idle -> returns at once; preparing -> awaits the in-flight `start` (it ends in recording or idle), then continues as
    /// recording; recording -> stop capture, close spools, write endedAt(.quit), release the lease, skip the AAC encode;
    /// stopping -> awaits it. The next launch's recovery finalizes with the same code path. Bounded work: well under a second
    /// (the caller also applies a 10 s timeout and replies regardless).
    public func stopForQuit() async { await stop(reason: .quit) }

    private func stop(reason: EndReason) async {
        while case .preparing = phase {
            await withCheckedContinuation { phaseWaiters.append($0) }
        }
        if case .recording = phase { beginStop(reason) }
        await stoppingTask?.value
    }

    private func beginStop(_ reason: EndReason) {
        clearMeterDisplay()
        let effects = transition(.stopRequested(reason))
        if effects.contains(.stopCapture(reason: reason)) { stoppingTask = Task { await finishStop() } }
    }

    private func finishStop() async {
        guard case .stopping(let stopping) = phase else { return }
        let diagnostics = await running?.stop() ?? .init()
        await eventTask?.value
        eventTask = nil; running = nil
        defer { lease?.release(); lease = nil; levels = nil; clearMeterDisplay() }
        do {
            let endedAt = deps.now()
            try await deps.store.update(stopping.ref) { meta in
                meta.capture = .finished(endedAt: endedAt, reason: stopping.reason)
                for (track, _) in meta.tracks.present { meta.tracks[track]?.diagnostics = diagnostics[track] }
            }
            let effects = transition(.captureStopped)
            if effects.contains(.finalize(stopping.ref, reason: stopping.reason)) {
                try await deps.finalizer.run(stopping.ref, reason: stopping.reason, clockDiagnostics: diagnostics, endedAt: endedAt)
                // The idle hook resumes queued jobs; neither it nor enqueue may observe a capture lease.
                lease?.release(); lease = nil
                for effect in transition(.finalizeSucceeded) {
                    if case .enqueueTranscription(let ref) = effect { hooks.sessionFinalized(ref) }
                }
            }
        } catch { _ = transition(.finalizeFailed) }
    }

    private func handle(_ event: CaptureEvent, ref: SessionRef) async {
        let health: TrackHealth?
        let track: Track
        switch phase {
        case .recording(let value) where value.ref == ref: break
        case .stopping(let value) where value.ref == ref: break
        default: return
        }
        switch event {
        case .meter(let t, let peak):
            guard case .recording = phase else { return }
            // Keep a short peak if a chunk delivers several display windows in one burst.
            let previous = pendingMeter[t]?.dbFS
            let value = peak.isFinite ? peak : -120
            pendingMeter[t] = MeterSample(dbFS: max(previous ?? -120, value), at: ProcessInfo.processInfo.systemUptime)
            return
        case .level(let t, let peak):
            track = t; levels?[t] = peak
            health = monitor.ingest(t, peakDBFS: peak, at: ProcessInfo.processInfo.systemUptime)
        case .digitalSilence(let t, let active):
            track = t; health = monitor.digitalSilence(t, active: active)
        case .trackFailed(let t, let failure):
            track = t
            do { try await deps.store.update(ref) { $0.tracks[t]?.failure = failure } }
            catch { FileHandle.standardError.write(Data("Could not persist track failure\n".utf8)) }
            health = .failed(failure)
        }
        if let health {
            let effects = transition(.trackHealthChanged(track, health))
            if effects.contains(.stopCapture(reason: .captureLost)) { stoppingTask = Task { await finishStop() } }
        }
    }

    private func startMeterDisplay() {
        clearMeterDisplay()
        meterLevels = .init(both: nil)
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self else { return }
                // One observable assignment per tick, even if a buffered source delivers a burst.
                var next = meterLevels
                for track in Track.allCases {
                    if let sample = pendingMeter[track] { next?[track] = sample }
                }
                pendingMeter = .init(both: nil)
                if meterLevels != next { meterLevels = next }
            }
        }
    }

    private func clearMeterDisplay() {
        meterTask?.cancel(); meterTask = nil
        pendingMeter = .init(both: nil); meterLevels = nil
    }

    @discardableResult
    private func transition(_ event: RecordingEvent) -> [RecordingEffect] {
        let result = phase.applying(event)
        guard result.kind == .moved else { return [] }
        phase = result.phase
        if case .stopping = phase { clearMeterDisplay() }
        hooks.phaseChanged(phase)
        let waiters = phaseWaiters; phaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return result.effects
    }

    // send(event): let t = phase.applying(event); if t.kind == .illegal -> log + return; phase = t.phase;
    // hooks.phaseChanged(phase); for e in t.effects { await perform(e) }
}
