import Foundation

/// The capture lifecycle. Transcription is NOT part of it (see TranscriptionService): a recording can start while an
/// earlier session is still queued for transcription, and a recovered/old session is transcribed without ever "recording".
///
/// Illegal states are unrepresentable: `recording` carries the session it is writing; `idle` carries nothing;
/// there is no `paused` (not in Phase 1, see design.md) and no `failed` (start failures are thrown to the UI,
/// mid-capture failures are per-track health, post-capture problems show up in the folder's `SessionState`).
public enum RecordingPhase: Sendable, Equatable {
    case idle
    case preparing(SessionDraft)
    case recording(Recording)
    case stopping(Stopping)

    public struct Recording: Sendable, Equatable {
        public let ref: SessionRef
        public let startedAt: Date
        public var health: TrackPair<TrackHealth>
    }
    public struct Stopping: Sendable, Equatable {
        public let ref: SessionRef
        public let reason: EndReason
    }
}

public enum TrackHealth: Sendable, Equatable {
    case waitingForAudio          // no level event yet
    case live
    case silent                   // peak < -75 dBFS for 20 s: informational (remote is normally silent before the call)
    case digitallySilent          // self only: >= 3 s of samples exactly 0.0 from the device (DigitalSilenceDetector): check the mic
    case failed(TrackFailure)     // terminal for this session
}

public enum RecordingEvent: Sendable, Equatable {
    case startRequested(SessionDraft)
    case prepared(SessionRef, startedAt: Date)
    case prepareFailed
    case trackHealthChanged(Track, TrackHealth)       // from SilenceMonitor and CaptureEvent
    case stopRequested(EndReason)
    case captureStopped                               // RunningCapture.stop() returned
    case finalizeSucceeded
    case finalizeFailed                               // spool remains => SessionState.needsFinalize
}

/// Side effects the *controller* performs; the reducer only names them. This keeps policy testable.
public enum RecordingEffect: Sendable, Equatable {
    case prepare(SessionDraft)
    case stopCapture(reason: EndReason)
    case finalize(SessionRef, reason: EndReason)
    case enqueueTranscription(SessionRef)
}

public struct Transition: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case moved, ignored, illegal }
    public var kind: Kind
    public var phase: RecordingPhase
    public var effects: [RecordingEffect]
}

extension RecordingPhase {
    /// Pure transition function. `.ignored` = benign late/duplicate event (state unchanged).
    /// `.illegal` = a caller bug (e.g. startRequested while recording); the controller logs and keeps the state.
    public func applying(_ event: RecordingEvent) -> Transition {
        func moved(_ p: RecordingPhase, _ e: [RecordingEffect] = []) -> Transition { .init(kind: .moved, phase: p, effects: e) }
        let ignored = Transition(kind: .ignored, phase: self, effects: [])
        let illegal = Transition(kind: .illegal, phase: self, effects: [])

        switch (self, event) {
        // idle
        case let (.idle, .startRequested(draft)): return moved(.preparing(draft), [.prepare(draft)])
        case (.idle, .stopRequested), (.idle, .trackHealthChanged), (.idle, .captureStopped),
             (.idle, .finalizeSucceeded), (.idle, .finalizeFailed): return ignored
        case (.idle, _): return illegal

        // preparing
        case let (.preparing, .prepared(ref, startedAt)):
            return moved(.recording(.init(ref: ref, startedAt: startedAt, health: .init(both: .waitingForAudio))))
        case (.preparing, .prepareFailed): return moved(.idle)
        case (.preparing, .trackHealthChanged): return ignored
        case (.preparing, _): return illegal   // incl. stopRequested: the UI disables Stop while preparing

        // recording
        case let (.recording(r), .trackHealthChanged(track, health)):
            var next = r
            if case .failed = r.health[track] { return ignored }       // failure is terminal
            next.health[track] = health
            if case .failed = next.health.me, case .failed = next.health.remote {
                // Both tracks gone: nothing left to record. Stop and keep what exists.
                return moved(.stopping(.init(ref: r.ref, reason: .captureLost)), [.stopCapture(reason: .captureLost)])
            }
            return moved(.recording(next))
        case let (.recording(r), .stopRequested(reason)):
            return moved(.stopping(.init(ref: r.ref, reason: reason)), [.stopCapture(reason: reason)])
        case (.recording, .captureStopped), (.recording, .finalizeSucceeded), (.recording, .finalizeFailed): return illegal
        case (.recording, _): return illegal

        // stopping
        case let (.stopping(s), .captureStopped):
            // .quit defers the (minutes-long) AAC encode to next launch; every other reason finalizes now.
            return s.reason == .quit ? moved(.idle) : moved(self, [.finalize(s.ref, reason: s.reason)])
        case let (.stopping(s), .finalizeSucceeded): return moved(.idle, [.enqueueTranscription(s.ref)])
        case (.stopping, .finalizeFailed): return moved(.idle)
        case (.stopping, .stopRequested), (.stopping, .trackHealthChanged): return ignored
        case (.stopping, _): return illegal
        }
    }
}

extension RecordingPhase {
    public var isCapturing: Bool {
        switch self { case .preparing, .recording, .stopping: true; case .idle: false }
    }
}
