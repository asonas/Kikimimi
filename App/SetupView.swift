import AppKit
import SwiftUI
import RecorderCore

struct SetupView: View {
    let env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("録音の準備").font(.title2).bold()
            VStack(alignment: .leading, spacing: 16) {
                row("画面収録", detail: screenText, ready: env.readiness.readiness.screen == .ready) {
                    switch env.readiness.readiness.screen {
                    case .notGranted(let requested):
                        if requested { Button("システム設定を開く") { openPrivacy("ScreenCapture") } }
                        else { Button("許可を要求") {
                            env.settings.settings.screenCaptureRequested = true
                            env.readiness.requestScreenCapture()
                        } }
                    case .grantedNeedsRelaunch: Button("再起動") { env.readiness.relaunchApp() }
                    case .grantedButFailing: Button("システム設定を開く") { openPrivacy("ScreenCapture") }
                    case .ready: EmptyView()
                    }
                }
                row("マイク", detail: micText, ready: env.readiness.readiness.mic == .authorized) {
                    switch env.readiness.readiness.mic {
                    case .notDetermined: Button("許可を要求") { Task { await env.readiness.requestMicrophone() } }
                    case .denied, .restricted: Button("システム設定を開く") { openPrivacy("Microphone") }
                    case .authorized: EmptyView()
                    }
                }
                row("マイク入力", detail: "入力デバイスの選択は今後追加します", ready: false) { EmptyView() }
                row("書き起こしモデル", detail: "未インストール。録音は可能です", ready: false) { EmptyView() }
            }
        }
        .padding(24)
        .frame(width: 580)
        .task {
            await env.launched.value
            while !Task.isCancelled {
                await env.readiness.refresh()
                logRows()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await env.readiness.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await env.readiness.refresh() }
        }
    }

    private func row<Actions: View>(_ title: String, detail: String, ready: Bool,
                                   @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ready ? Color.green : Color.orange)
                .accessibilityLabel(ready ? "準備完了" : "確認が必要")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions()
        }
    }

    private var screenText: String {
        switch env.readiness.readiness.screen {
        case .ready: "準備完了"
        case .notGranted: "画面収録の許可が必要です"
        case .grantedNeedsRelaunch: "許可されました。再起動してください"
        case .grantedButFailing(let code): "収録の確認に失敗しました（\(code)）"
        }
    }
    private var micText: String {
        switch env.readiness.readiness.mic {
        case .authorized: "準備完了"
        case .notDetermined: "マイクの許可が必要です"
        case .denied: "マイクへのアクセスが拒否されています"
        case .restricted: "マイクへのアクセスが制限されています"
        }
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
    private func logRows() {
        #if DEBUG
        let screen = env.readiness.readiness.screen
        let mic = env.readiness.readiness.mic
        FileHandle.standardError.write(Data("SETUP screen=\(screen) microphone=\(mic) input=notChosen model=notInstalled\n".utf8))
        #endif
    }
}
