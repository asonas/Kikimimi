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
    @ObservationIgnored private var operations: [SessionRef: (id: UUID, task: Task<Void, Never>)] = [:]

    init(environment: AppEnvironment) { self.environment = environment }

    func start(ref: SessionRef) {
        guard operations[ref] == nil, let env = environment else { return }
        let id = UUID()
        let model = env.settings.settings.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = env.summaryTokenSource
        jobs[ref] = .running
        let task = Task {
            do {
                let transcript = try String(contentsOf: ref.folder.transcript, encoding: .utf8)
                let result = try await ResponsesClient().summarize(transcript: transcript, model: model, tokenSource: source)
                try Task.checkCancellation()
                try await env.store.saveSummary(ref, markdown: result)
                if operations[ref]?.id == id { jobs[ref] = .finished(Date()) }
            } catch {
                if operations[ref]?.id == id {
                    jobs[ref] = error is CancellationError || Task.isCancelled ? nil : .failed(error.localizedDescription)
                }
            }
            // An old cancelled task must not clear a replacement job for the same session.
            if operations[ref]?.id == id { operations[ref] = nil }
            await env.chatGPT.refresh()
        }
        operations[ref] = (id, task)
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
