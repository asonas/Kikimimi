import SwiftUI
import RecorderCore

enum NoteExportStep {
    case confirming(URL)
    case exporting(URL)
    case done(SessionExport)
}

struct NoteExportSheet: View {
    let step: NoteExportStep
    let target: String
    let hasSummary: Bool
    let cancel: () -> Void
    let confirm: (URL) -> Void
    let close: () -> Void

    var body: some View {
        MainSheet {
            switch step {
            case .confirming(let destination), .exporting(let destination):
                Text("ノートを書き出す").kikimimiText(.heading)
                Text(target).kikimimiText(.label)
                VStack(alignment: .leading, spacing: 12) {
                    Text("保存先").kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                    Text(destinationLabel(destination)).kikimimiText(.label).help(destination.path)
                    Text("含める内容").kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                    Text(NoteExportLabels.contents(hasSummary: hasSummary)).kikimimiText(.label)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(KikimimiColor.paper, in: RoundedRectangle(cornerRadius: 8))
                Text("同じ録音のノートがあれば、内容を更新します。")
                    .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                HStack {
                    Button("キャンセル", action: cancel).buttonStyle(KikimimiButtonStyle.secondary).disabled(isExporting)
                    Spacer()
                    Button("書き出す") { confirm(destination) }.buttonStyle(KikimimiButtonStyle.primary)
                        .keyboardShortcut(.defaultAction).disabled(isExporting)
                }
            case .done(let exported):
                SettingsStatus(text: "ノートを書き出しました", showsDot: true)
                Text(target).kikimimiText(.heading)
                Text("\(destinationLabel(URL(fileURLWithPath: exported.path).deletingLastPathComponent())) に保存しました。")
                    .kikimimiText(.body).foregroundStyle(KikimimiColor.secondary).help(exported.path)
                Button("録音に戻る", action: close).buttonStyle(KikimimiButtonStyle.primary)
            }
        }
        .interactiveDismissDisabled(isExporting)
    }
    private var isExporting: Bool { if case .exporting = step { true } else { false } }
    private func destinationLabel(_ folder: URL) -> String {
        NoteExportLabels.destination(folder: folder, home: FileManager.default.homeDirectoryForCurrentUser)
    }
}
