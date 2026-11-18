import Foundation
import Testing
@testable import RecorderCore

@Test @MainActor func settingsPersistAndRecoverFromInvalidJSON() throws {
    let suite = "interview-recorder-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(defaults: defaults)
    #expect(store.settings.mic == nil)
    store.settings.mic = .init(deviceUID: "uid", deviceName: "Mic", channel: 2)
    store.settings.screenCaptureRequested = true
    store.settings.language = "en"
    #expect(SettingsStore(defaults: defaults).settings == store.settings)
    defaults.set(Data("invalid json".utf8), forKey: "settings.v1")
    #expect(SettingsStore(defaults: defaults).settings == Settings())
}

@Test @MainActor func settingsSavedBeforeAutoFollowUpKeepEveryFieldAndStayOff() throws {
    let suite = "interview-recorder-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var saved = Settings()
    saved.mic = .init(deviceUID: "uid", deviceName: "Mic", channel: 2)
    saved.summaryConsent = true
    saved.exportFolder = "/Users/x/Notes"
    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
    json.removeValue(forKey: "autoSummarizeAndExport")
    defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "settings.v1")
    let loaded = SettingsStore(defaults: defaults).settings
    #expect(loaded == saved)
    #expect(!loaded.autoSummarizeAndExport)
}

@Test func autoFollowUpListsEveryMissingRequirementInOrder() {
    #expect(AutoFollowUpRequirement.missing(modelReady: true, providerReady: true, summaryModel: "gpt", exportFolder: "/n").isEmpty)
    #expect(AutoFollowUpRequirement.missing(modelReady: false, providerReady: false, summaryModel: " \n", exportFolder: nil)
            == [.transcriptionModel, .summaryProvider, .summaryModel, .exportFolder])
    #expect(AutoFollowUpRequirement.missing(modelReady: true, providerReady: false, summaryModel: "gpt", exportFolder: "/n")
            == [.summaryProvider])
    #expect(AutoFollowUpRequirement.missing(modelReady: true, providerReady: true, summaryModel: "gpt", exportFolder: nil)
            == [.exportFolder])
}

// PermissionProbe's synchronous methods may be called from any thread.
private final class SetupProbe: PermissionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false
    private var probeCalls = 0
    private var requests = 0
    private var mic: MicAccess = .notDetermined
    func screenPreflight() -> Bool { lock.withLock { granted } }
    func screenProbe() async -> ScreenCaptureAccess.Probe {
        lock.withLock { probeCalls += 1 }
        return .failed(code: -42)
    }
    func requestScreen() { lock.withLock { requests += 1; granted = true } }
    func micStatus() -> MicAccess { lock.withLock { mic } }
    func requestMic() async -> Bool { lock.withLock { mic = .authorized }; return true }
    var counts: (Int, Int) { lock.withLock { (probeCalls, requests) } }
}

private struct EmptySetupDevices: InputDeviceCatalog {
    func inputDevices() throws -> [InputDeviceInfo] { [] }
}

@Test @MainActor func readinessRefreshNeverRequestsPermissionAndRelaunchIsExplicit() async {
    let probe = SetupProbe()
    var relaunches = 0
    let model = ReadinessModel(probe: probe, devices: EmptySetupDevices(), mic: { nil }, model: { .notInstalled },
        requestedScreenBefore: false, relaunch: { relaunches += 1 })
    await model.refresh()
    #expect(model.readiness.screen == .notGranted(requestedBefore: false))
    #expect(probe.counts.0 == 0)
    #expect(probe.counts.1 == 0)
    model.relaunchApp()
    #expect(relaunches == 0)
    model.requestScreenCapture()
    #expect(probe.counts.1 == 1)
    #expect(relaunches == 0)
    await model.refresh()
    #expect(probe.counts.0 == 1)
    #expect(model.readiness.screen == .grantedNeedsRelaunch)
    #expect(model.readiness.micDevice == .notChosen)
    model.relaunchApp()
    #expect(relaunches == 1)
    await model.requestMicrophone()
    #expect(model.readiness.mic == .authorized)
}
