import AppKit
import RecorderCore
import SwiftUI

struct RecordingPane: View {
    let env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @State private var devices: [InputDeviceInfo] = []
    @State private var inputError: String?
    @State private var peak: Float = -120

    var body: some View {
        Form {
            Section("許可") {
                row("画面収録", detail: screenText, ready: env.readiness.readiness.screen == .ready) {
                    switch env.readiness.readiness.screen {
                    case .notGranted(let requested):
                        if requested {
                            Button("システム設定を開く") { openPrivacy("ScreenCapture") }
                        } else {
                            Button("許可を要求") {
                                env.settings.settings.screenCaptureRequested = true
                                env.readiness.requestScreenCapture()
                            }
                        }
                    case .grantedNeedsRelaunch: Button("再起動") { env.readiness.relaunchApp() }
                    case .grantedButFailing: Button("システム設定を開く") { openPrivacy("ScreenCapture") }
                    case .ready: EmptyView()
                    }
                }
                row("マイク", detail: micText, ready: env.readiness.readiness.mic == .authorized) {
                    switch env.readiness.readiness.mic {
                    case .notDetermined:
                        Button("許可を要求") { Task { await env.readiness.requestMicrophone() } }
                    case .denied, .restricted: Button("システム設定を開く") { openPrivacy("Microphone") }
                    case .authorized: EmptyView()
                    }
                }
            }
            Section("マイク入力") { microphoneInput }
            if let remote = env.settings.settings.remote {
                Section("相手の音声") {
                    switch remote {
                    case .allSystemAudio: LabeledContent("保存済みの選択", value: "システム全体の音声")
                    case .app(_, let name): LabeledContent("保存済みのアプリ", value: name)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await env.launched.value
            while !Task.isCancelled {
                refreshDevices()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .task(id: previewKey) {
            peak = -120
            guard scenePhase == .active, !env.recorder.phase.isCapturing,
                env.readiness.readiness.mic == .authorized,
                let choice = env.settings.settings.mic,
                let device = devices.first(where: { $0.uid == choice.deviceUID })
            else { return }
            do {
                let levels = try await env.microphoneLevels(device: device, channel: choice.channel)
                for try await value in levels { peak = value }
            } catch is CancellationError {} catch {
                if !Task.isCancelled { inputError = "入力の確認に失敗しました: \(error.localizedDescription)" }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await env.readiness.refresh() } }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await env.readiness.refresh() }
        }
    }

    private var previewKey: String {
        let uid = env.settings.settings.mic?.deviceUID ?? ""
        let channels = devices.first(where: { $0.uid == uid })?.inputChannels ?? 0
        return
            "\(uid)/\(env.settings.settings.mic?.channel ?? 0)/\(scenePhase)/\(env.recorder.phase.isCapturing)/\(env.readiness.readiness.mic)/\(channels)"
    }

    private var microphoneInput: some View {
        Group {
            Picker(
                "デバイス",
                selection: Binding(
                    get: { env.settings.settings.mic?.deviceUID ?? "" },
                    set: { uid in
                        inputError = nil
                        env.settings.settings.mic = devices.first(where: { $0.uid == uid }).map {
                            MicPreference(deviceUID: $0.uid, deviceName: $0.name, channel: nil)
                        }
                        Task { await env.readiness.refresh() }
                    })
            ) {
                Text("選択してください").tag("")
                if let choice = env.settings.settings.mic,
                    !devices.contains(where: { $0.uid == choice.deviceUID })
                {
                    Text("\(choice.deviceName)（未接続）").tag(choice.deviceUID)
                }
                ForEach(devices, id: \.uid) { Text($0.name).tag($0.uid) }
            }
            if let choice = env.settings.settings.mic {
                Text("UID: \(choice.deviceUID)").font(.caption).foregroundStyle(.secondary)
                    .textSelection(
                        .enabled)
                if let device = devices.first(where: { $0.uid == choice.deviceUID }) {
                    Picker(
                        "チャンネル",
                        selection: Binding(
                            get: { choice.channel ?? 0 },
                            set: { value in
                                inputError = nil
                                env.settings.settings.mic?.channel = value == 0 ? nil : value
                                Task { await env.readiness.refresh() }
                            })
                    ) {
                        Text("全チャンネル（ミックス）").tag(0)
                        ForEach(1...device.inputChannels, id: \.self) {
                            Text("INPUT \($0)").tag($0)
                        }
                    }
                }
                HStack {
                    ProgressView(value: Double(min(1, max(0, (peak + 75) / 75))))
                        .accessibilityLabel("マイク入力レベル")
                    Text(String(format: "%.0f dBFS", peak)).font(.caption.monospacedDigit()).frame(
                        width: 76)
                }
                Text(env.recorder.phase.isCapturing ? "録音中は入力の確認を停止しています" : "話してメーターが動くことを確認してください")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("使用する入力を選んでください。自動では選択しません").font(.subheadline).foregroundStyle(.secondary)
            }
            if let inputError { Text(inputError).font(.caption).foregroundStyle(.red) }
        }
        .pickerStyle(.menu)
        .disabled(env.recorder.phase.isCapturing)
    }

    private func refreshDevices() {
        do {
            let next = try env.inputDevices()
            if next != devices {
                devices = next
                #if DEBUG
                    for device in next {
                        FileHandle.standardError.write(
                            Data(
                                "SETUP inputDevice=\(device.name) uid=\(device.uid) channels=\(device.inputChannels)\n"
                                    .utf8))
                    }
                #endif
            }
        } catch { inputError = "入力デバイスを取得できませんでした: \(error.localizedDescription)" }
    }

    private func row<Actions: View>(
        _ title: String, detail: String, ready: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ready ? Color.green : Color.orange)
                .accessibilityLabel(ready ? "準備完了" : "確認が必要")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
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
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
