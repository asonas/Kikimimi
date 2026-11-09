import Foundation
import Observation

// MARK: - Screen recording: the request-then-relaunch problem, as a pure derivation

public enum ScreenCaptureAccess: Sendable, Equatable {
    /// Never asked or denied. macOS does not distinguish; `requestedBefore` (our own flag) only picks the wording
    /// and whether the button says "Request" (system dialog) or "Open System Settings".
    case notGranted(requestedBefore: Bool)
    /// Preflight is true now but was false at launch: the grant exists in TCC but this process cannot capture yet.
    /// The UI offers "Relaunch now" (user-initiated; never exit right after the request: that records "Denied").
    case grantedNeedsRelaunch
    /// Preflight true but a functional probe (SCShareableContent) failed. Stale TCC row after re-signing, or an OS
    /// re-confirmation pending. UI: show the error code, offer System Settings.
    case grantedButFailing(code: Int)
    case ready

    public enum Probe: Sendable, Equatable { case succeeded, failed(code: Int) }

    /// Pure. `probe` is only attempted when `preflightNow` is true (probing without access can pop a system prompt).
    public static func derive(preflightAtLaunch: Bool, preflightNow: Bool, requestedBefore: Bool, probe: Probe?) -> ScreenCaptureAccess {
        guard preflightNow else { return .notGranted(requestedBefore: requestedBefore) }
        if case .succeeded? = probe { return .ready }
        if !preflightAtLaunch { return .grantedNeedsRelaunch }
        if case let .failed(code)? = probe { return .grantedButFailing(code: code) }
        return .ready   // probe not run yet: optimistic until the first probe lands (UI shows "checking")
    }
}

public enum MicAccess: Sendable, Equatable { case notDetermined, denied, restricted, authorized }

public enum ModelStatus: Sendable, Equatable {
    case notInstalled
    case downloading(fraction: Double)
    case optimizing                     // first-time Core ML specialization for this Mac
    case ready
    case failed(String)
}

public enum ReadinessBlocker: Sendable, Equatable {
    case screenCapture(ScreenCaptureAccess)
    case microphonePermission(MicAccess)
    case micNotChosen
    case micMissing(MicPreference)
    case micChannelOutOfRange(MicPreference, deviceChannels: Int)
}

/// What the menu shows before an interview. Derived from inputs; nothing here is stored.
public struct Readiness: Sendable, Equatable {
    public var screen: ScreenCaptureAccess
    public var mic: MicAccess
    public var micDevice: MicResolution
    public var model: ModelStatus

    /// Blocks *recording*. The model never blocks recording (audio is safe; transcription waits for the model).
    public var blockers: [ReadinessBlocker] {
        var result: [ReadinessBlocker] = []
        if screen != .ready { result.append(.screenCapture(screen)) }
        if mic != .authorized { result.append(.microphonePermission(mic)) }
        switch micDevice {
        case .notChosen: result.append(.micNotChosen)
        case .deviceMissing(let preference): result.append(.micMissing(preference))
        case let .channelOutOfRange(device, requested):
            let preference = MicPreference(deviceUID: device.uid, deviceName: device.name, channel: requested)
            result.append(.micChannelOutOfRange(preference, deviceChannels: device.inputChannels))
        case .use: break
        }
        return result
    }
    public var canRecord: Bool { blockers.isEmpty }
}

/// OS-facing probes. Implemented in RecorderAudio (CGPreflight*, AVCaptureDevice, SCShareableContent).
public protocol PermissionProbe: Sendable {
    func screenPreflight() -> Bool
    func screenProbe() async -> ScreenCaptureAccess.Probe
    /// Shows the system dialog. The caller must NOT terminate the process afterwards.
    func requestScreen()
    func micStatus() -> MicAccess
    func requestMic() async -> Bool
}

/// Owns `readiness` for the UI. `refresh()` is called: at launch, on NSApplication.didBecomeActive,
/// and every 1 s while the onboarding window is visible (the user is toggling System Settings).
@MainActor @Observable
public final class ReadinessModel {
    public private(set) var readiness: Readiness
    private let probe: any PermissionProbe
    private let devices: any InputDeviceCatalog
    private let mic: @MainActor () -> MicPreference?
    private let model: @MainActor () -> ModelStatus
    private let relaunch: @MainActor () -> Void
    private let preflightAtLaunch: Bool
    private var requestedScreenBefore: Bool
    private var refreshing = false
    public init(probe: any PermissionProbe, devices: any InputDeviceCatalog, mic: @escaping @MainActor () -> MicPreference?,
                model: @escaping @MainActor () -> ModelStatus, requestedScreenBefore: Bool, relaunch: @escaping @MainActor () -> Void) {
        self.probe = probe
        self.devices = devices
        self.mic = mic
        self.model = model
        self.relaunch = relaunch
        self.requestedScreenBefore = requestedScreenBefore
        preflightAtLaunch = probe.screenPreflight()
        readiness = Readiness(screen: .derive(preflightAtLaunch: preflightAtLaunch,
            preflightNow: preflightAtLaunch, requestedBefore: requestedScreenBefore, probe: nil),
            mic: probe.micStatus(), micDevice: .notChosen, model: model())
    }
    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let now = probe.screenPreflight()
        let result = now ? await probe.screenProbe() : nil
        readiness = Readiness(screen: .derive(preflightAtLaunch: preflightAtLaunch,
            preflightNow: now, requestedBefore: requestedScreenBefore, probe: result),
            mic: probe.micStatus(), micDevice: .resolve(mic(), available: (try? devices.inputDevices()) ?? []),
            model: model())
    }
    // The Setup action persists the flag through SettingsStore before invoking the OS request.
    public func requestScreenCapture() {
        requestedScreenBefore = true
        probe.requestScreen()
    }
    public func requestMicrophone() async {
        _ = await probe.requestMic()
        await refresh()
    }
    public func relaunchApp() {
        guard readiness.screen == .grantedNeedsRelaunch else { return }
        relaunch()
    }
}
