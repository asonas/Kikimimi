import SwiftUI

struct SummarySettingsView: View {
    let env: AppEnvironment
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("要約（OpenAI）").font(.headline)
            Text(env.summaryCredentials.hasKey ? "APIキーを保存済み" : "APIキーは未保存")
                .font(.subheadline).foregroundStyle(.secondary)
            SecureField("OpenAI APIキー", text: $key)
            HStack {
                Button("保存") {
                    env.summaryCredentials.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                    key = ""
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("削除") { env.summaryCredentials.delete(); key = "" }
                    .disabled(!env.summaryCredentials.hasKey)
            }
            TextField("モデル", text: Binding(get: { env.settings.settings.summaryModel },
                                             set: { env.settings.settings.summaryModel = $0 }))
            Text("書き起こしは、要約ボタンを押したときだけOpenAIへ送信されます。APIの利用料金がかかります")
                .font(.caption).foregroundStyle(.secondary)
            if let error = env.summaryCredentials.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { env.summaryCredentials.refresh() }
        .onDisappear { key = "" }
    }
}
