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
}

/// What the menu shows before an interview. Derived from inputs; nothing here is stored.
public struct Readiness: Sendable, Equatable {
    public var screen: ScreenCaptureAccess
    public var mic: MicAccess
    public var micDevice: MicResolution
    public var model: ModelStatus

    /// Blocks *recording*. The model never blocks recording (audio is safe; transcription waits for the model).
    public var blockers: [ReadinessBlocker] { fatalError("not implemented") }
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
    public init(probe: any PermissionProbe, devices: any InputDeviceCatalog, mic: @escaping @MainActor () -> MicPreference?,
                model: @escaping @MainActor () -> ModelStatus, requestedScreenBefore: Bool, relaunch: @escaping @MainActor () -> Void) {
        fatalError("not implemented")
    }
    public func refresh() async { fatalError("not implemented") }
    public func requestScreenCapture() { fatalError("not implemented") }   // also persists requestedBefore = true
    public func requestMicrophone() async { fatalError("not implemented") }
    public func relaunchApp() { fatalError("not implemented") }            // only offered when .grantedNeedsRelaunch
}
