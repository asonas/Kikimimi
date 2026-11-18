import Foundation
import Observation
import RecorderCore
import RecorderSummary

enum SummaryJob: Sendable, Equatable {
    case running
    case failed(String)
    case finished(Date)
}

@MainActor @Observable
final class SummaryJobs {
    private(set) var jobs: [SessionRef: SummaryJob] = [:]
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var operations: [SessionRef: (id: UUID, task: Task<SummaryJob?, Never>)] = [:]

    init(environment: AppEnvironment) { self.environment = environment }

    /// Returns the task of this session's summary, including one that was already running. Its value is that run's own
    /// result: `.finished`, `.failed`, or nil when it was cancelled. `jobs[ref]` may already belong to a later run.
    @discardableResult
    func start(ref: SessionRef) -> Task<SummaryJob?, Never>? {
        if let running = operations[ref] { return running.task }
        guard let env = environment else { return nil }
        let id = UUID()
        let model = env.settings.settings.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = env.summaryTokenSource
        let usesChatGPT = env.settings.settings.summaryProvider == .chatGPT
        jobs[ref] = .running
        let task = Task { () -> SummaryJob? in
            var outcome: SummaryJob?
            do {
                let transcript = try String(contentsOf: ref.folder.transcript, encoding: .utf8)
                let result = try await ResponsesClient().summarize(transcript: transcript, model: model, tokenSource: source)
                try Task.checkCancellation()
                try await env.store.saveSummary(ref, markdown: result)
                outcome = .finished(Date())
            } catch {
                outcome = error is CancellationError || Task.isCancelled ? nil : .failed(error.localizedDescription)
            }
            // `cancel` removed this run, maybe after the save had committed: it still counts as cancelled.
            // An old cancelled task must not touch a replacement job for the same session either.
            if operations[ref]?.id == id { jobs[ref] = outcome; operations[ref] = nil } else { outcome = nil }
            // Not awaited: a slow keychain read must not hold back the result the automatic export waits for.
            // Only after a ChatGPT run, which may have rotated its tokens; the API key path never reads that item.
            if usesChatGPT { Task { await env.chatGPT.refresh() } }
            return outcome
        }
        operations[ref] = (id, task)
        return task
    }

    func cancel(ref: SessionRef) {
        guard let operation = operations.removeValue(forKey: ref) else { return }
        operation.task.cancel()
        jobs[ref] = nil
    }

    func cancelAll() {
        for ref in Array(operations.keys) { cancel(ref: ref) }
    }
}
