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
        SettingsPage("録音") {
            SettingsSection("録音に必要な許可") {
                SettingsRow("マイク", description: "自分の声を録音します。" + (env.readiness.readiness.mic == .authorized ? "" : "\n" + micText)) {
                    switch env.readiness.readiness.mic {
                    case .notDetermined: Button("許可を要求") { Task { await env.readiness.requestMicrophone() } }
                    case .denied, .restricted: Button("システム設定を開く") { openPrivacy("Microphone") }
                    case .authorized: SettingsStatus(text: "許可済み")
                    }
                }
                SettingsDivider()
                SettingsRow("画面収録", description: "相手のアプリの音声を取り込みます。映像は保存しません。" + (env.readiness.readiness.screen == .ready ? "" : "\n" + screenText)) {
                    switch env.readiness.readiness.screen {
                    case .notGranted(let requested):
                        if requested { Button("システム設定を開く") { openPrivacy("ScreenCapture") } }
                        else { Button("許可を要求") {
                            env.settings.settings.screenCaptureRequested = true
                            env.readiness.requestScreenCapture()
                        } }
                    case .grantedNeedsRelaunch: Button("再起動") { env.readiness.relaunchApp() }
                    case .grantedButFailing: Button("システム設定を開く") { openPrivacy("ScreenCapture") }
                    case .ready: SettingsStatus(text: "許可済み")
                    }
                }
            }
            microphoneInput
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("マイクの入力").font(KikimimiFont.label.font)
                        Spacer()
                        Text(String(format: "%.0f dBFS", peak)).font(KikimimiFont.number.font)
                    }
                    ProgressView(value: Double(min(1, max(0, (peak + 75) / 75))))
                        .tint(KikimimiColor.meterGreen).accessibilityLabel("マイク入力レベル")
                }
                .padding(24).foregroundStyle(.white)
                .background(KikimimiColor.meterPanel, in: RoundedRectangle(cornerRadius: 8))
                Text("声を出して確認できます。録音中はここでの入力確認を停止します。")
                    .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
            }
            if let inputError { Text(inputError).kikimimiText(.small).foregroundStyle(KikimimiColor.danger) }
            SettingsSection("相手の音声") {
                SettingsRow("前回選んだアプリ", description: "録音を始めるときに変更できます。") {
                    switch env.settings.settings.remote {
                    case .allSystemAudio: Text("システム全体の音声")
                    case .app(_, let name): Text(name)
                    case nil: Text("未選択").foregroundStyle(KikimimiColor.secondary)
                    }
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 8) {
            SettingsSection("自分の音声") {
                SettingsRow("マイク", description: "使用する入力を選びます。") {
                    Picker("デバイス", selection: Binding(get: { env.settings.settings.mic?.deviceUID ?? "" }, set: { uid in
                        inputError = nil
                        env.settings.settings.mic = devices.first(where: { $0.uid == uid }).map {
                            MicPreference(deviceUID: $0.uid, deviceName: $0.name, channel: nil)
                        }
                        Task { await env.readiness.refresh() }
                    })) {
                        Text("選択してください").tag("")
                        if let choice = env.settings.settings.mic, !devices.contains(where: { $0.uid == choice.deviceUID }) {
                            Text("\(choice.deviceName)（未接続）").tag(choice.deviceUID)
                        }
                        ForEach(devices, id: \.uid) { Text($0.name).tag($0.uid) }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(minHeight: 40)
                }
                SettingsDivider()
                SettingsRow("入力チャンネル") {
                    if let choice = env.settings.settings.mic, let device = devices.first(where: { $0.uid == choice.deviceUID }) {
                        Picker("チャンネル", selection: Binding(get: { choice.channel ?? 0 }, set: { value in
                            inputError = nil
                            env.settings.settings.mic?.channel = value == 0 ? nil : value
                            Task { await env.readiness.refresh() }
                        })) {
                            Text("全チャンネル（ミックス）").tag(0)
                            ForEach(1...device.inputChannels, id: \.self) { Text("INPUT \($0)").tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(minHeight: 40)
                    } else {
                        Text("マイクを選択してください").foregroundStyle(KikimimiColor.secondary)
                    }
                }
            }
            if let choice = env.settings.settings.mic {
                Text("UID: \(choice.deviceUID)").kikimimiText(.small).foregroundStyle(KikimimiColor.secondary).textSelection(.enabled)
            } else {
                Text("使用する入力を選んでください。自動では選択しません").kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
            }
        }
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
