import Foundation
import Observation
import Sparkle

/// Owns Sparkle. Updates are offered, never installed silently (no SUAutomaticallyUpdate).
@MainActor @Observable
final class AppUpdater: NSObject {
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private let isRecording: @MainActor () -> Bool
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(isRecording: @escaping @MainActor () -> Bool) {
        self.isRecording = isRecording
        super.init()
    }

    /// Not called in headless mode: a scripted run must not open an update window.
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

extension AppUpdater: @MainActor SPUUpdaterDelegate {
    /// A scheduled check must not put an update window over an interview. The next scheduled check retries.
    /// A check the user asked for is allowed; installing quits through `applicationShouldTerminate`, which
    /// stops and saves the recording first.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, isRecording() else { return }
        throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "録音中はアップデートを確認しません"])
    }
}
