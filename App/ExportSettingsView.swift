import AppKit
import SwiftUI

struct ExportSettingsView: View {
    let env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("書き出し").font(.headline)
            if let path = env.settings.settings.exportFolder {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).textSelection(.enabled)
            } else {
                Text("書き出し先は未設定です").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                Button("フォルダを選択…") { chooseFolder() }
                if let path = env.settings.settings.exportFolder {
                    Button("Finder で表示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
                    }
                    Button("解除") { env.settings.settings.exportFolder = nil }
                }
            }
            Text("各録音の「ノートを書き出す」で、同じ名前のノートを上書きします。自動では書き出しません")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "選択"
        if let path = env.settings.settings.exportFolder { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        panel.begin { response in
            if response == .OK, let url = panel.url { env.settings.settings.exportFolder = url.path }
        }
    }
}
