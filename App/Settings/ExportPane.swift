import AppKit
import SwiftUI

struct ExportPane: View {
    let env: AppEnvironment
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
            VStack(alignment: .leading, spacing: 24) {
                Text("書き出す内容").kikimimiText(.heading)
                VStack(alignment: .leading, spacing: 0) {
                    Text("会社名・タイトル・日時").kikimimiText(.body)
                    Text("文字起こし（話者・時刻付き）").kikimimiText(.body)
                    Text("要約（作成されている場合）").kikimimiText(.body)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("各録音の「ノートを書き出す」から保存します。").kikimimiText(.small)
                    Text("同じ録音を書き出すと、同じ名前のノートを更新します。").kikimimiText(.small)
                    Text("音声ファイルはこのフォルダにコピーされません。").kikimimiText(.small)
                }.foregroundStyle(KikimimiColor.secondary)
            }
            if env.settings.settings.exportFolder != nil {
                Button("保存先の設定を解除") { env.settings.settings.exportFolder = nil }.buttonStyle(KikimimiButtonStyle.text)
            }
        }
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
