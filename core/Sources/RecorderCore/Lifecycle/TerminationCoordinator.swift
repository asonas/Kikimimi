import Foundation
import Observation

/// One application quit request. A non-cooperative stop must not prevent the timeout reply.
@MainActor @Observable
public final class TerminationCoordinator {
    public private(set) var requested = false
    @ObservationIgnored private var replied = false
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var reply: (() -> Void)?

    public init() {}

    public func request(stop: @escaping @MainActor () async -> Void,
                        timeout: Duration = .seconds(10),
                        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                        reply: @escaping @MainActor () -> Void) {
        guard !requested else { return }
        requested = true
        self.reply = reply
        stopTask = Task { [weak self] in
            await stop()
            self?.finish()
        }
        timeoutTask = Task { [weak self] in
            do { try await sleep(timeout); self?.finish() }
            catch { /* Cancellation after a successful stop does not reply again. */ }
        }
    }

    private func finish() {
        guard !replied else { return }
        replied = true
        let callback = reply; reply = nil
        stopTask?.cancel(); timeoutTask?.cancel()
        stopTask = nil; timeoutTask = nil
        callback?()
    }
}
