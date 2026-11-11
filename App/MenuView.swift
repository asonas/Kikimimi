import AppKit
import SwiftUI
import RecorderCore

struct MenuView: View {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kikimimi").font(.headline)
            switch env.recorder.phase {
            case .idle:
                Button("新しい録音") {
                    env.navigation.prepare()
                    AppDelegate.showMainWindow?()
                }
                    .disabled(env.termination.requested)
                Button("ウィンドウを開く") { show("main") }
            case .preparing: Text("録音を準備しています")
            case .recording(let recording):
                HStack { Text("録音中"); Text(recording.startedAt, style: .timer).monospacedDigit() }
                Button("録音を停止") { Task { await env.recorder.stop() } }
            case .stopping: Text("録音を保存しています")
            }
            Divider()
            Button("終了") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: 260)
    }

    private func show(_ id: String) {
        if id == "main" { AppDelegate.showMainWindow?(); return }
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
