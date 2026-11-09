import Foundation
import Testing
@testable import RecorderCore

@Test func recordingPhaseFullPhaseEventTable() {
    let draft = SessionDraft(company: "Acme", remote: .allSystemAudio)
    let ref = SessionRef(id: UUID(), folder: .init(url: URL(fileURLWithPath: "/tmp/table")))
    let start = Date(timeIntervalSince1970: 1000)
    let recording = RecordingPhase.recording(.init(ref: ref, startedAt: start, health: .init(both: .waitingForAudio)))
    let stopping = RecordingPhase.stopping(.init(ref: ref, reason: .user))
    let phases: [RecordingPhase] = [.idle, .preparing(draft), recording, stopping]
    let events: [RecordingEvent] = [.startRequested(draft), .prepared(ref, startedAt: start), .prepareFailed,
        .trackHealthChanged(.me, .live), .stopRequested(.user), .captureStopped, .finalizeSucceeded, .finalizeFailed]
    let kinds: [[Transition.Kind]] = [
        [.moved, .illegal, .illegal, .ignored, .ignored, .ignored, .ignored, .ignored],
        [.illegal, .moved, .moved, .ignored, .illegal, .illegal, .illegal, .illegal],
        [.illegal, .illegal, .illegal, .moved, .moved, .illegal, .illegal, .illegal],
        [.illegal, .illegal, .illegal, .ignored, .ignored, .moved, .moved, .moved],
    ]
    for (p, phase) in phases.enumerated() {
        for (e, event) in events.enumerated() {
            let transition = phase.applying(event)
            #expect(transition.kind == kinds[p][e])
            if transition.kind != .moved {
                #expect(transition.phase == phase)
                #expect(transition.effects.isEmpty)
            } else {
                switch (p, e) {
                case (0, 0):
                    #expect(transition.phase == .preparing(draft))
                    #expect(transition.effects == [.prepare(draft)])
                case (1, 1): #expect(transition.phase == recording); #expect(transition.effects.isEmpty)
                case (1, 2), (3, 7): #expect(transition.phase == .idle); #expect(transition.effects.isEmpty)
                case (2, 3):
                    if case .recording(let r) = transition.phase { #expect(r.health == .init(me: .live, remote: .waitingForAudio)) }
                    else { Issue.record("expected recording") }
                    #expect(transition.effects.isEmpty)
                case (2, 4): #expect(transition.phase == stopping); #expect(transition.effects == [.stopCapture(reason: .user)])
                case (3, 5): #expect(transition.phase == stopping); #expect(transition.effects == [.finalize(ref, reason: .user)])
                case (3, 6): #expect(transition.phase == .idle); #expect(transition.effects == [.enqueueTranscription(ref)])
                default: Issue.record("uncovered transition")
                }
            }
            if transition.effects.contains(.enqueueTranscription(ref)) {
                #expect(event == .finalizeSucceeded)
            }
        }
    }
}

@Test func recordingPhaseFailuresAreTerminalAndBothFailuresStop() {
    let ref = SessionRef(id: UUID(), folder: .init(url: URL(fileURLWithPath: "/tmp/table")))
    let failure = TrackFailure(code: .deviceLost, message: "unplugged")
    let phase = RecordingPhase.recording(.init(ref: ref, startedAt: Date(), health: .init(me: .failed(failure), remote: .live)))
    for health in [TrackHealth.live, .silent, .digitallySilent, .failed(failure)] {
        let ignored = phase.applying(.trackHealthChanged(.me, health))
        #expect(ignored.kind == .ignored)
        #expect(ignored.phase == phase)
        #expect(ignored.effects.isEmpty)
    }
    let lost = phase.applying(.trackHealthChanged(.remote, .failed(failure)))
    #expect(lost.phase == .stopping(.init(ref: ref, reason: .captureLost)))
    #expect(lost.effects == [.stopCapture(reason: .captureLost)])
    #expect(lost.phase.applying(.captureStopped).effects == [.finalize(ref, reason: .captureLost)])
    let quit = RecordingPhase.stopping(.init(ref: ref, reason: .quit)).applying(.captureStopped)
    #expect(quit.phase == .idle)
    #expect(quit.effects.isEmpty)
}
