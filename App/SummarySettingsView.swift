import SwiftUI
import RecorderCore

struct SummarySettingsView: View {
    let env: AppEnvironment
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("要約（OpenAI）").font(.headline)
            Picker("使う方法", selection: Binding(get: { env.settings.settings.summaryProvider },
                                                 set: {
                env.settings.settings.summaryProvider = $0; key = ""
                if $0 == .apiKey { env.chatGPT.cancel() }
            })) {
                Text("ChatGPT でサインイン").tag(SummaryProvider.chatGPT)
                Text("API キー").tag(SummaryProvider.apiKey)
            }
            if env.settings.settings.summaryProvider == .chatGPT {
                Text("プレビュー").font(.caption).foregroundStyle(.secondary)
                if env.chatGPT.signedIn, let email = env.chatGPT.email {
                    Text(email).textSelection(.enabled)
                }
                if env.chatGPT.waiting {
                    HStack {
                        ProgressView("ブラウザーでのサインインを待っています")
                        Button("キャンセル") { env.chatGPT.cancel() }
                    }
                } else {
                    Button("ChatGPT でサインイン") { env.chatGPT.signIn() }.disabled(env.chatGPT.signingOut)
                }
                if env.chatGPT.signedIn {
                    Button(env.chatGPT.signingOut ? "サインアウト中…" : "サインアウト") {
                        Task { await env.chatGPT.signOut() }
                    }
                    .disabled(env.chatGPT.waiting || env.chatGPT.signingOut)
                }
                Text("Plus は 5 時間ごとの利用上限を他のアプリと共有します")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = env.chatGPT.error { Text(error).font(.caption).foregroundStyle(.red) }
            } else {
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
                if let error = env.summaryCredentials.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            TextField("モデル", text: Binding(get: { env.settings.settings.summaryModel },
                                             set: { env.settings.settings.summaryModel = $0 }))
            Text("書き起こしは、要約ボタンを押したときだけOpenAIへ送信されます")
                .font(.caption).foregroundStyle(.secondary)
            if env.settings.settings.summaryProvider == .apiKey {
                Text("APIの利用料金がかかります")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { env.summaryCredentials.refresh(); await env.chatGPT.refresh() }
        .onDisappear { key = "" }
    }
}
