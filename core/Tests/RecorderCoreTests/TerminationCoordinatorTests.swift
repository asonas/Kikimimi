import Testing
@testable import RecorderCore

@MainActor private final class QuitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var entered = false
    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor private func eventually(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<10000 { if condition() { return }; await Task.yield() }
    Issue.record("quit operation did not progress")
}

@Test @MainActor func terminationRepliesAfterImmediateStop() async {
    let coordinator = TerminationCoordinator(), timeout = QuitGate()
    var stopped = false, replies = 0
    coordinator.request(stop: { stopped = true }, sleep: { duration in
        #expect(duration == .seconds(10)); await timeout.wait()
    }, reply: {
        #expect(stopped); replies += 1
    })
    await eventually { replies == 1 }
    timeout.release()
    await Task.yield()
    #expect(coordinator.requested)
    #expect(replies == 1)
}

@Test @MainActor func terminationTimeoutRepliesDespiteNonCooperativeStopAndIgnoresLateCompletion() async {
    let coordinator = TerminationCoordinator(), stop = QuitGate(), timeout = QuitGate()
    var finished = false, replies = 0
    coordinator.request(stop: {
        await stop.wait() // Deliberately ignores Task cancellation.
        finished = true
    }, timeout: .milliseconds(1), sleep: { duration in
        #expect(duration == .milliseconds(1)); await timeout.wait()
    }, reply: { replies += 1 })
    await eventually { stop.entered && timeout.entered }
    timeout.release()
    await eventually { replies == 1 }
    #expect(!finished)
    stop.release()
    await eventually { finished }
    #expect(replies == 1)
}

@Test @MainActor func terminationDuplicateRequestsShareOneStopAndOneReply() async {
    let coordinator = TerminationCoordinator(), stop = QuitGate(), timeout = QuitGate()
    var stops = 0, replies = 0
    coordinator.request(stop: { stops += 1; await stop.wait() }, sleep: { _ in await timeout.wait() }, reply: { replies += 1 })
    coordinator.request(stop: { Issue.record("duplicate stop") }, sleep: { _ in Issue.record("duplicate timeout") }, reply: {
        Issue.record("duplicate reply")
    })
    await eventually { stop.entered }
    stop.release()
    await eventually { replies == 1 }
    timeout.release()
    await Task.yield()
    coordinator.request(stop: { Issue.record("stop after reply") }, reply: { Issue.record("reply after reply") })
    #expect(stops == 1)
    #expect(replies == 1)
}

@Test @MainActor func terminationStopBeforeTimeoutWinsEvenWhenCancelledTimeoutCompletes() async {
    let coordinator = TerminationCoordinator(), stop = QuitGate(), timeout = QuitGate()
    var replies = 0, timeoutCompleted = false
    coordinator.request(stop: { await stop.wait() }, sleep: { _ in
        await timeout.wait()
        timeoutCompleted = true
    }, reply: { replies += 1 })
    await eventually { stop.entered && timeout.entered }
    stop.release()
    await eventually { replies == 1 }
    timeout.release()
    await eventually { timeoutCompleted }
    #expect(replies == 1)
}
