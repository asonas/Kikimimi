import AppKit
import RecorderCore
import SwiftUI

struct ExportPane: View {
    let env: AppEnvironment
    @State private var confirmingAuto = false
    var body: some View {
        SettingsPage("書き出し", description: "録音ごとに、文字起こしと要約を1つのノートにまとめます。") {
            SettingsSection("ノートの保存先") {
                SettingsRow("フォルダ", description: env.settings.settings.exportFolder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "未設定") {
                    Button(env.settings.settings.exportFolder == nil ? "フォルダを選択" : "フォルダを変更") { chooseFolder() }
                }
                SettingsDivider()
                SettingsRow("選択したフォルダを確認") {
                    Button("Finderで表示") {
                        if let path = env.settings.settings.exportFolder { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)]) }
                    }.disabled(env.settings.settings.exportFolder == nil)
                }
            }
            SettingsSection("自動で処理") {
                SettingsRow("文字起こしが終わったら、要約してノートを書き出す", description: autoDescription) {
                    Toggle(isOn: Binding(get: { autoEnabled }, set: { on in
                        if on { confirmingAuto = true } else {
                            env.settings.settings.autoSummarizeAndExport = false
                            env.autoFollowUp.switchTurnedOff()
                        }
                    })) { Text(autoEnabled ? "オン" : "オフ") }
                    .labelsHidden().toggleStyle(.switch).tint(KikimimiColor.ink).frame(minHeight: 40).fixedSize()
                    // Turning it off stays possible after a setting was undone; only turning it on needs every setting.
                    .disabled(!autoEnabled && !missing.isEmpty)
                    .accessibilityLabel("文字起こしが終わったら、要約してノートを書き出す")
                }
            }
            VStack(alignment: .leading, spacing: 24) {
                Text("書き出す内容").kikimimiText(.heading)
                VStack(alignment: .leading, spacing: 0) {
                    Text("会社名・タイトル・日時").kikimimiText(.body)
                    Text("文字起こし（話者・時刻付き）").kikimimiText(.body)
                    Text("要約（作成されている場合）").kikimimiText(.body)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("同じ録音を書き出すと、同じ名前のノートを更新します。").kikimimiText(.small)
                    Text("音声ファイルはこのフォルダにコピーされません。").kikimimiText(.small)
                }.foregroundStyle(KikimimiColor.secondary)
            }
            if env.settings.settings.exportFolder != nil {
                Button("保存先の設定を解除") { env.settings.settings.exportFolder = nil }.buttonStyle(KikimimiButtonStyle.text)
            }
        }
        .sheet(isPresented: $confirmingAuto) {
            MainSheet {
                Text("文字起こしが終わるたびに送信します").kikimimiText(.heading)
                Text("新しい録音の文字起こしが終わると、設定しているモデルプロバイダーへ送信して要約し、ノートに書き出します。\n音声ファイルは送信しません。")
                    .kikimimiText(.body)
                Text("あとから設定でオフにできます。").kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                HStack {
                    Button("キャンセル") { confirmingAuto = false }.buttonStyle(KikimimiButtonStyle.secondary)
                    Spacer()
                    Button("オンにする") {
                        confirmingAuto = false
                        // A folder moved in Finder while the sheet was open does not redraw it, so check again here.
                        // The description then names what is missing.
                        guard missing.isEmpty else { return }
                        env.settings.settings.summaryConsent = true
                        env.settings.settings.autoSummarizeAndExport = true
                    }
                    .buttonStyle(KikimimiButtonStyle.primary).keyboardShortcut(.defaultAction).disabled(!missing.isEmpty)
                }
            }
        }
    }
    private var autoEnabled: Bool { env.settings.settings.autoSummarizeAndExport }
    private var missing: [AutoFollowUpRequirement] { env.autoFollowUp.missingRequirements }
    private var autoDescription: String {
        guard !missing.isEmpty else {
            return autoEnabled ? "新しい録音が対象です。文字起こしを、設定しているモデルプロバイダーに送信します。"
                : "オンにすると、新しい録音の文字起こしを、設定しているモデルプロバイダーに送信します。"
        }
        let steps = missing.map(\.instruction).joined(separator: "\n")
        return (autoEnabled ? "次の設定が済むまで、自動では行いません。\n" : "次の設定が済むと使えます。\n") + steps
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true; panel.prompt = "選択"
        if let path = env.settings.settings.exportFolder { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        panel.begin { response in
            if response == .OK, let url = panel.url { env.settings.settings.exportFolder = url.path }
        }
    }
}
