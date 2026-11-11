import RecorderCore
import SwiftUI

struct SummaryPane: View {
    let env: AppEnvironment
    @State private var key = ""
    private var usesChatGPT: Bool { env.settings.settings.summaryProvider == .chatGPT }

    var body: some View {
        SettingsPage(usesChatGPT ? "要約" : "APIキーで要約する",
                     description: usesChatGPT ? "文字起こしをOpenAIへ送り、面接の要点をまとめます。" : "OpenAI APIで使用するキーとモデルを設定します。") {
            KikimimiSegmentedChoice(options: [(SummaryProvider.chatGPT, "ChatGPTでサインイン"), (.apiKey, "APIキーを使う")],
                                    selection: Binding(get: { env.settings.settings.summaryProvider }, set: {
                env.setSummaryProvider($0); key = ""
                if $0 == .apiKey { env.chatGPT.cancel() }
            }))
            .accessibilityLabel("使う方法")
            if usesChatGPT { chatGPTSection } else { apiKeySection }
            SettingsSection("要約に使うモデル") { SummaryModelPicker(env: env) }
            VStack(alignment: .leading, spacing: 0) {
                Text("「要約を作成」を押したときだけ、文字起こしを送信します。").kikimimiText(.body)
                Text("音声ファイルは送信しません。").kikimimiText(.body)
            }.foregroundStyle(KikimimiColor.secondary)
            Text(usesChatGPT ? "ChatGPTの利用上限は、ほかのアプリと共有します。" : "OpenAI APIの利用料金がかかります。")
                .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(KikimimiColor.paper, in: RoundedRectangle(cornerRadius: 8))
        }
        .task { env.summaryCredentials.refresh(); await env.chatGPT.refresh() }
        .onDisappear { key = "" }
    }

    private var chatGPTSection: some View {
        SettingsSection("ChatGPT") {
            SettingsRow("アカウント", description: env.chatGPT.email ?? "未サインイン") {
                HStack(spacing: 12) {
                    if env.chatGPT.waiting {
                        ProgressView("ブラウザーでのサインインを待っています")
                        Button("キャンセル") { env.chatGPT.cancel() }
                    } else if !env.chatGPT.signedIn {
                        Button("サインイン") { env.chatGPT.signIn() }.disabled(env.chatGPT.signingOut)
                    }
                    if env.chatGPT.signedIn {
                        Text("サインイン済み")
                        Button(env.chatGPT.signingOut ? "サインアウト中…" : "サインアウト") { Task { await env.chatGPT.signOut() } }
                            .disabled(env.chatGPT.waiting || env.chatGPT.signingOut)
                    }
                }
            }
            if let error = env.chatGPT.error {
                Text(error).kikimimiText(.small).foregroundStyle(KikimimiColor.danger).padding(16)
            }
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APIキー").kikimimiText(.label)
            SecureField("保存済みのキーは表示しません。", text: $key).kikimimiField()
                .accessibilityLabel("OpenAI APIキー")
            Text("キーはmacOSのキーチェーンに保存します。")
                .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
            Text(env.summaryCredentials.hasKey ? "APIキーを保存済み" : "APIキーは未保存")
                .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
            HStack(spacing: 12) {
                Button("キーを保存") {
                    env.summaryCredentials.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""
                }
                .buttonStyle(KikimimiButtonStyle.primary)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("保存したキーを削除") { env.summaryCredentials.delete(); key = "" }
                    .disabled(!env.summaryCredentials.hasKey)
            }.padding(.top, 16)
            if let error = env.summaryCredentials.error { Text(error).kikimimiText(.small).foregroundStyle(KikimimiColor.danger) }
        }
    }
}
