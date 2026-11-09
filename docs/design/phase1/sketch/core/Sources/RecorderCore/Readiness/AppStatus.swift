import Foundation

/// What the menu bar icon and the first line of the menu say. DERIVED from the two independent machines; stored nowhere.
/// Priority: a live recording always wins, because the user must never wonder whether it is recording.
public enum AppStatus: Sendable, Equatable {
    case recording(startedAt: Date, trackProblem: Bool)   // red icon; amber badge if a track failed, is silent, or is digitally silent
    case preparing
    case saving                                           // stopping: closing spools, encoding AAC
    case transcribing(fraction: Double, queued: Int)
    case needsAttention(String)                           // not ready / failed job / unfinalized session
    case idle

    public static func derive(phase: RecordingPhase, jobs: [TranscriptionJob], readiness: Readiness) -> AppStatus {
        switch phase {
        case let .recording(r):
            let bad = [r.health.me, r.health.remote].contains { h in
                switch h { case .failed, .silent, .digitallySilent: true; case .waitingForAudio, .live: false }
            }
            return .recording(startedAt: r.startedAt, trackProblem: bad)
        case .preparing: return .preparing
        case .stopping: return .saving
        case .idle:
            if let running = jobs.first(where: { if case .running = $0.state { true } else { false } }),
               case let .running(f) = running.state {
                return .transcribing(fraction: f, queued: jobs.count { $0.state == .queued })
            }
            // TODO: failed job => .needsAttention("文字起こしに失敗"); !readiness.canRecord => .needsAttention("セットアップが必要")
            return .idle
        }
    }
}
