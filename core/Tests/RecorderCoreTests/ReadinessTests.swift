import Foundation
import Testing
@testable import RecorderCore

private struct ScreenCase: Sendable {
    let atLaunch: Bool
    let now: Bool
    let probe: ScreenCaptureAccess.Probe?
    let expected: ScreenCaptureAccess
}

private let screenCases: [ScreenCase] = [
    .init(atLaunch: false, now: false, probe: nil, expected: .notGranted(requestedBefore: false)),
    .init(atLaunch: false, now: false, probe: .succeeded, expected: .notGranted(requestedBefore: false)),
    .init(atLaunch: false, now: false, probe: .failed(code: -1), expected: .notGranted(requestedBefore: false)),
    .init(atLaunch: true, now: false, probe: nil, expected: .notGranted(requestedBefore: false)),
    .init(atLaunch: true, now: false, probe: .succeeded, expected: .notGranted(requestedBefore: false)),
    .init(atLaunch: true, now: false, probe: .failed(code: -1), expected: .notGranted(requestedBefore: false)),
    .init(atLaunch: false, now: true, probe: nil, expected: .grantedNeedsRelaunch),
    .init(atLaunch: false, now: true, probe: .failed(code: -1), expected: .grantedNeedsRelaunch),
    .init(atLaunch: false, now: true, probe: .succeeded, expected: .ready),
    .init(atLaunch: true, now: true, probe: nil, expected: .ready),
    .init(atLaunch: true, now: true, probe: .failed(code: -1), expected: .grantedButFailing(code: -1)),
    .init(atLaunch: true, now: true, probe: .succeeded, expected: .ready),
]

@Test(arguments: screenCases, [false, true])
private func screenCaptureAccessTruthTable(row: ScreenCase, requestedBefore: Bool) {
    let expected: ScreenCaptureAccess
    if case .notGranted = row.expected { expected = .notGranted(requestedBefore: requestedBefore) }
    else { expected = row.expected }
    #expect(ScreenCaptureAccess.derive(preflightAtLaunch: row.atLaunch, preflightNow: row.now,
        requestedBefore: requestedBefore, probe: row.probe) == expected)
}

private let rubix = InputDeviceInfo(uid: "rubix", name: "Rubix44", inputChannels: 4, isSystemDefault: false)
private let defaultMic = InputDeviceInfo(uid: "built-in", name: "Rubix44", inputChannels: 1, isSystemDefault: true)
private func preference(_ channel: Int?) -> MicPreference {
    .init(deviceUID: rubix.uid, deviceName: "Old device name", channel: channel)
}

private struct MicCase: Sendable {
    let preference: MicPreference?
    let available: [InputDeviceInfo]
    let expected: MicResolution
}

private let micCases: [MicCase] = [
    .init(preference: nil, available: [defaultMic, rubix], expected: .notChosen),
    .init(preference: preference(1), available: [], expected: .deviceMissing(preference(1))),
    .init(preference: preference(1), available: [defaultMic], expected: .deviceMissing(preference(1))),
    .init(preference: preference(nil), available: [defaultMic, rubix], expected: .use(device: rubix, channel: nil)),
    .init(preference: preference(1), available: [defaultMic, rubix], expected: .use(device: rubix, channel: 1)),
    .init(preference: preference(4), available: [rubix, defaultMic], expected: .use(device: rubix, channel: 4)),
    .init(preference: preference(0), available: [rubix], expected: .channelOutOfRange(device: rubix, requested: 0)),
    .init(preference: preference(-1), available: [rubix], expected: .channelOutOfRange(device: rubix, requested: -1)),
    .init(preference: preference(5), available: [defaultMic, rubix], expected: .channelOutOfRange(device: rubix, requested: 5)),
]

@Test(arguments: micCases)
private func micResolutionMatchesUIDAndNeverFallsBack(row: MicCase) {
    #expect(MicResolution.resolve(row.preference, available: row.available) == row.expected)
}

@Test private func readinessBlockersHaveStableOrder() {
    let screens: [ScreenCaptureAccess] = [.notGranted(requestedBefore: false), .notGranted(requestedBefore: true),
        .grantedNeedsRelaunch, .grantedButFailing(code: -1), .ready]
    let permissions: [MicAccess] = [.notDetermined, .denied, .restricted, .authorized]
    let resolutions: [(MicResolution, ReadinessBlocker?)] = [
        (.notChosen, .micNotChosen),
        (.deviceMissing(preference(1)), .micMissing(preference(1))),
        (.channelOutOfRange(device: rubix, requested: 5),
            .micChannelOutOfRange(.init(deviceUID: rubix.uid, deviceName: rubix.name, channel: 5), deviceChannels: 4)),
        (.use(device: rubix, channel: 1), nil),
    ]
    for screen in screens {
        for permission in permissions {
            for (resolution, deviceBlocker) in resolutions {
                var expected: [ReadinessBlocker] = []
                if screen != .ready { expected.append(.screenCapture(screen)) }
                if permission != .authorized { expected.append(.microphonePermission(permission)) }
                if let deviceBlocker { expected.append(deviceBlocker) }
                let readiness = Readiness(screen: screen, mic: permission, micDevice: resolution, model: .ready)
                #expect(readiness.blockers == expected)
                #expect(readiness.canRecord == expected.isEmpty)
            }
        }
    }
}

private let models: [ModelStatus] = [.notInstalled, .downloading(fraction: 0.5), .optimizing, .ready, .failed("error")]
private func ready(_ model: ModelStatus = .ready) -> Readiness {
    .init(screen: .ready, mic: .authorized, micDevice: .use(device: rubix, channel: 1), model: model)
}

@Test(arguments: models)
private func modelStatusNeverBlocksRecording(model: ModelStatus) {
    #expect(ready(model).blockers.isEmpty)
    #expect(ready(model).canRecord)
    #expect(AppStatus.derive(phase: .idle, jobs: [], readiness: ready(model)) == .idle)
}

private let session = SessionRef(id: UUID(), folder: SessionFolder(url: URL(fileURLWithPath: "/tmp/readiness-tests")))
private let startedAt = Date(timeIntervalSince1970: 100)
private let blocked = Readiness(screen: .grantedNeedsRelaunch, mic: .denied, micDevice: .notChosen, model: .notInstalled)
private func job(_ state: TranscriptionJobState) -> TranscriptionJob { .init(ref: session, state: state) }
private let healths: [TrackHealth] = [.waitingForAudio, .live, .silent, .digitallySilent,
    .failed(.init(code: .deviceLost, message: "unplugged"))]

@Test(arguments: healths, healths)
private func recordingOutranksJobsAndReadiness(me: TrackHealth, remote: TrackHealth) {
    let phase = RecordingPhase.recording(.init(ref: session, startedAt: startedAt,
        health: .init(me: me, remote: remote)))
    let healthy: [TrackHealth] = [.waitingForAudio, .live]
    let problem = !healthy.contains(me) || !healthy.contains(remote)
    #expect(AppStatus.derive(phase: phase, jobs: [job(.failed("error")), job(.running(fraction: 0.5)), job(.queued)],
        readiness: blocked) == .recording(startedAt: startedAt, trackProblem: problem))
}

@Test private func preparingAndSavingOutrankJobsAndReadiness() {
    let draft = SessionDraft(company: "Example", remote: .allSystemAudio)
    let rows: [(RecordingPhase, AppStatus)] = [(.preparing(draft), .preparing),
        (.stopping(.init(ref: session, reason: .user)), .saving)]
    for (phase, expected) in rows {
        #expect(AppStatus.derive(phase: phase, jobs: [job(.running(fraction: 0.5)), job(.failed("error"))],
            readiness: blocked) == expected)
    }
}

@Test private func idleStatusPriorityTable() {
    let rows: [([TranscriptionJob], Readiness, AppStatus)] = [
        ([job(.running(fraction: 0.4)), job(.queued), job(.queued), job(.waiting(.modelNotReady)),
            job(.failed("error")), job(.done)], blocked, .transcribing(fraction: 0.4, queued: 2)),
        ([job(.failed("error"))], blocked, .needsAttention("文字起こしに失敗")),
        ([job(.failed("error"))], ready(), .needsAttention("文字起こしに失敗")),
        ([], blocked, .needsAttention("セットアップが必要")),
        ([job(.queued), job(.waiting(.modelNotReady)), job(.done)], ready(), .idle),
        ([], ready(), .idle),
    ]
    for (jobs, readiness, expected) in rows {
        #expect(AppStatus.derive(phase: .idle, jobs: jobs, readiness: readiness) == expected)
    }
}
