import AppKit
import SwiftUI

struct ExportPane: View {
    let env: AppEnvironment

    var body: some View {
        Form {
            Section {
                LabeledContent("フォルダ") {
                    Text(
                        env.settings.settings.exportFolder.map {
                            ($0 as NSString).abbreviatingWithTildeInPath
                        }
                            ?? "未設定"
                    )
                    .textSelection(.enabled)
                    Spacer()
                    Button("フォルダを選択…") { chooseFolder() }
                    if let path = env.settings.settings.exportFolder {
                        Menu("その他") {
                            Button("Finder で表示") {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: path, isDirectory: true)
                                ])
                            }
                            Button("解除") { env.settings.settings.exportFolder = nil }
                        }
                        .fixedSize()
                    }
                }
            } header: {
                Text("書き出し先")
            } footer: {
                Text("録音ごとに1つのノートを書き出します。各録音の「ノートを書き出す」で同じ名前のノートを上書きします。自動では書き出しません。")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "選択"
        if let path = env.settings.settings.exportFolder {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        panel.begin { response in
            if response == .OK, let url = panel.url {
                env.settings.settings.exportFolder = url.path
            }
        }
    }
}
