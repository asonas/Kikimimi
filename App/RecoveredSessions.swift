import Observation
import RecorderCore

/// Shared with the launch task before AppEnvironment is initialized; no persistence or recovery side effects.
@MainActor @Observable
final class RecoveredSessions {
    var refs: [SessionRef] = []
}
