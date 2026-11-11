import RecorderCore
import SwiftUI

struct SummaryPane: View {
    let env: AppEnvironment
    @State private var key = ""

    var body: some View {
        Form {
            Section("方法") {
                Picker(
                    "使う方法",
                    selection: Binding(
                        get: { env.settings.settings.summaryProvider },
                        set: {
                            env.setSummaryProvider($0)
                            key = ""
                            if $0 == .apiKey { env.chatGPT.cancel() }
                        })
                ) {
                    Text("ChatGPT でサインイン").tag(SummaryProvider.chatGPT)
                    Text("API キー").tag(SummaryProvider.apiKey)
                }
                .pickerStyle(.segmented)
            }
            if env.settings.settings.summaryProvider == .chatGPT {
                Section("アカウント") {
                    LabeledContent("アカウント") {
                        Text(env.chatGPT.email ?? "未サインイン").textSelection(.enabled)
                        Spacer()
                        if env.chatGPT.waiting {
                            HStack {
                                ProgressView("ブラウザーでのサインインを待っています")
                                Button("キャンセル") { env.chatGPT.cancel() }
                            }
                        } else if !env.chatGPT.signedIn {
                            Button("サインイン") { env.chatGPT.signIn() }.disabled(
                                env.chatGPT.signingOut)
                        }
                        if env.chatGPT.signedIn {
                            Button(env.chatGPT.signingOut ? "サインアウト中…" : "サインアウト") {
                                Task { await env.chatGPT.signOut() }
                            }
                            .disabled(env.chatGPT.waiting || env.chatGPT.signingOut)
                        }
                    }
                    if let error = env.chatGPT.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            } else {
                Section("API キー") {
                    Text(env.summaryCredentials.hasKey ? "APIキーを保存済み" : "APIキーは未保存")
                        .font(.subheadline).foregroundStyle(.secondary)
                    SecureField("OpenAI APIキー", text: $key)
                    HStack {
                        Spacer()
                        Button("保存") {
                            env.summaryCredentials.save(
                                key.trimmingCharacters(in: .whitespacesAndNewlines))
                            key = ""
                        }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("削除") {
                            env.summaryCredentials.delete()
                            key = ""
                        }
                        .disabled(!env.summaryCredentials.hasKey)
                    }
                    if let error = env.summaryCredentials.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Section {
                SummaryModelPicker(env: env)
            } header: {
                Text("モデル")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if env.settings.settings.summaryProvider == .chatGPT {
                        Text("Plus は 5 時間ごとの利用上限を他のアプリと共有します")
                    }
                    Text("書き起こしは、要約ボタンを押したときだけ OpenAI へ送信されます")
                        .font(.caption).foregroundStyle(.secondary)
                    if env.settings.settings.summaryProvider == .apiKey {
                        Text("APIの利用料金がかかります")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            env.summaryCredentials.refresh()
            await env.chatGPT.refresh()
        }
        .onDisappear { key = "" }
    }
}
