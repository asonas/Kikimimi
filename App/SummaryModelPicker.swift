import Observation
import RecorderCore
import RecorderSummary
import SwiftUI

@MainActor @Observable
final class SummaryModelLists {
    private(set) var lists: [SummaryProvider: [SummaryModel]] = [:]
    private(set) var errors: [SummaryProvider: String] = [:]
    private var requests: [SummaryProvider: UUID] = [:]
    private let client = SummaryModelsClient()

    func isLoading(_ provider: SummaryProvider) -> Bool { requests[provider] != nil }

    func reload(provider: SummaryProvider, source: any BearerTokenSource) async {
        let id = UUID()
        requests[provider] = id; errors[provider] = nil
        defer { if requests[provider] == id { requests[provider] = nil } }
        do {
            let models = try await client.models(provider: provider, tokenSource: source)
            guard !Task.isCancelled, requests[provider] == id else { return }
            lists[provider] = models
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled, requests[provider] == id { errors[provider] = error.localizedDescription }
        }
    }
}

struct SummaryModelPicker: View {
    let env: AppEnvironment

    private struct RequestKey: Equatable {
        let provider: SummaryProvider
        let ready: Bool
        let revision: Int
    }

    private var requestKey: RequestKey {
        let provider = env.settings.settings.summaryProvider
        return RequestKey(provider: provider, ready: env.summaryProviderReady,
                          revision: provider == .apiKey ? env.summaryCredentials.revision : env.chatGPT.revision)
    }

    var body: some View {
        let provider = env.settings.settings.summaryProvider
        let models = env.summaryModels.lists[provider] ?? []
        let selection = Binding(get: { env.settings.settings.summaryModel }, set: { env.settings.settings.summaryModel = $0 })
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if env.summaryModels.errors[provider] != nil || !env.summaryProviderReady {
                    TextField("モデル", text: selection)
                } else {
                    Picker("モデル", selection: selection) {
                        if !models.contains(where: { $0.id == env.settings.settings.summaryModel }) {
                            Text("\(env.settings.settings.summaryModel)（一覧にありません）").tag(env.settings.settings.summaryModel)
                        }
                        ForEach(models) { model in Text(model.displayName ?? model.id).tag(model.id) }
                    }
                    .pickerStyle(.menu)
                }
                if env.summaryModels.isLoading(provider) {
                    ProgressView().controlSize(.small).accessibilityLabel("モデル一覧を取得中")
                }
                Button("再読み込み") { Task { await reload() } }
                    .disabled(!env.summaryProviderReady || env.summaryModels.isLoading(provider))
            }
            if let error = env.summaryModels.errors[provider] { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: requestKey) {
            guard env.summaryProviderReady else { return }
            await reload()
        }
    }

    private func reload() async {
        await env.summaryModels.reload(provider: env.settings.settings.summaryProvider, source: env.summaryTokenSource)
        await env.chatGPT.refresh()
    }
}
