import AppKit
import SwiftUI
import RecorderCore

struct NewRecordingView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var company = ""
    @State private var title = ""
    @State private var candidates: [RemoteSource] = []
    @State private var selection = ""
    @State private var error: String?

    var body: some View {
        Form {
            TextField("会社名（必須）", text: $company)
            TextField("タイトル（任意）", text: $title, prompt: Text("二次面接など"))
            Picker("相手の音声", selection: $selection) {
                ForEach(candidates, id: \.selectionID) { source in Text(source.label).tag(source.selectionID) }
            }
            if selectedSource == .allSystemAudio {
                Text("通知など、他のアプリの音も録音されます").font(.caption).foregroundStyle(.secondary)
            }
            if !env.readiness.readiness.canRecord {
                Text("設定で録音の準備を完了してください").foregroundStyle(.secondary)
                Button("設定を開く") { openWindow(id: "setup") }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("録音を開始") {
                    guard let source = selectedSource else { return }
                    let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        do {
                            try await env.recorder.start(.init(company: company, title: label.isEmpty ? nil : label, remote: source))
                            env.settings.settings.remote = source
                            error = nil; company = ""; title = ""
                            dismiss()
                        } catch { self.error = "録音を開始できませんでした: \(error)" }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(company.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedSource == nil ||
                          !env.readiness.readiness.canRecord || env.recorder.phase.isCapturing)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 520)
        .task {
            do {
                candidates = try await env.remoteCandidates()
                let saved = env.settings.settings.remote?.selectionID
                selection = candidates.first(where: { $0.selectionID == saved })?.selectionID ?? candidates.first?.selectionID ?? ""
            } catch { self.error = "音声アプリを取得できませんでした: \(error.localizedDescription)" }
        }
    }

    private var selectedSource: RemoteSource? { candidates.first { $0.selectionID == selection } }
}

private extension RemoteSource {
    var selectionID: String {
        switch self { case .app(let id, _): id; case .allSystemAudio: "all-system-audio" }
    }
    var label: String {
        switch self { case .app(_, let name): name; case .allSystemAudio: "全システム音" }
    }
}
