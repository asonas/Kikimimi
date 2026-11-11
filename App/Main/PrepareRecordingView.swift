import AppKit
import SwiftUI
import RecorderCore

struct PrepareRecordingView: View {
    let env: AppEnvironment
    let event: CalendarEvent?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var company: String
    @State private var title = ""
    @State private var candidates: [RemoteSource] = []
    @State private var selection = ""
    @State private var devices: [InputDeviceInfo] = []
    @State private var level: MeterSample?
    @State private var previewing = false
    @State private var previewFailed = false
    @State private var error: String?
    @State private var previewError: String?
    @State private var visible = false
    @State private var starting = false
    @State private var previewTask: Task<Void, Never>?

    init(env: AppEnvironment, event: CalendarEvent?) {
        self.env = env; self.event = event
        _company = State(initialValue: event?.title ?? "")
    }

    var body: some View {
        MainPage {
            VStack(alignment: .leading, spacing: 4) {
                Text("録音の準備").kikimimiText(.title)
                if let event {
                    Text("\(SessionDate.upcoming(start: event.start, end: event.end).replacingOccurrences(of: "  ", with: " "))  /  \(event.calendarTitle)")
                        .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                }
            }
            HStack(alignment: .top, spacing: 24) {
                field("会社名（必須）", text: $company)
                field("タイトル（任意）", text: $title)
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("録音する音声").kikimimiText(.heading)
                    Spacer()
                    Text("自分と相手を分けて保存").kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                }
                HStack(alignment: .top, spacing: 24) { microphoneCard; remoteCard }
                HStack(spacing: 12) {
                    SettingsStatus(text: env.readiness.readiness.mic == .authorized ? "マイクの許可済み" : "マイクの許可が必要です",
                                   ready: env.readiness.readiness.mic == .authorized, showsDot: true)
                    Text("・").foregroundStyle(KikimimiColor.secondary)
                    SettingsStatus(text: env.readiness.readiness.screen == .ready ? "画面収録の許可済み" : "画面収録の準備が必要です",
                                   ready: env.readiness.readiness.screen == .ready, showsDot: true)
                }
            }
            if !env.readiness.readiness.canRecord {
                HStack {
                    Text("設定で録音の準備を完了してください").kikimimiText(.label).foregroundStyle(KikimimiColor.warning)
                    Spacer()
                    Button("設定を開く", action: showRecordingSettings).buttonStyle(KikimimiButtonStyle.secondary)
                }
                .padding(16).background(KikimimiColor.warningBg, in: RoundedRectangle(cornerRadius: 8))
            }
            if let error { Text(error).kikimimiText(.small).foregroundStyle(KikimimiColor.danger).textSelection(.enabled) }
            HStack(spacing: 16) {
                Text("文字起こしは録音を止めた後に始まります。")
                    .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                Spacer()
                Button("キャンセル") { env.navigation.cancelPrepare() }.buttonStyle(KikimimiButtonStyle.secondary).disabled(starting)
                Button(starting ? "録音を準備しています" : "録音を開始", action: start)
                    .buttonStyle(KikimimiButtonStyle.primary).keyboardShortcut(.defaultAction).disabled(startDisabled)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; previewTask?.cancel() }
        .task {
            await env.launched.value
            do {
                candidates = try await env.remoteCandidates()
                guard !Task.isCancelled else { return }
                selection = EventRemoteApp.select(meetingURL: event?.meetingURL, candidateBundleIDs: candidates.map(\.selectionID),
                                                  savedID: env.settings.settings.remote?.selectionID) ?? ""
            } catch { if !Task.isCancelled { self.error = "音声アプリを取得できませんでした: \(error.localizedDescription)" } }
            while !Task.isCancelled {
                do { devices = try env.inputDevices() }
                catch { previewError = "入力デバイスを取得できませんでした: \(error.localizedDescription)" }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .task(id: previewKey) {
            let task = Task { await preview() }
            previewTask = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await env.readiness.refresh() } }
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).kikimimiText(.label)
            TextField(label, text: text).labelsHidden().kikimimiField().disabled(starting)
        }
        .frame(maxWidth: .infinity)
    }
    private var microphoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自分").kikimimiText(.heading)
            HStack(spacing: 8) {
                Text(microphoneLabel).kikimimiText(.label)
                Spacer()
                Button("変更", action: showRecordingSettings).buttonStyle(KikimimiButtonStyle.text).disabled(starting)
            }
            LiveLevelMeter(channel: "マイクの入力", sample: level, expectedLive: previewing, failed: previewFailed)
            Text("話してメーターが動くことを確認できます。")
                .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
            if let previewError { Text(previewError).kikimimiText(.small).foregroundStyle(KikimimiColor.warning) }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(KikimimiColor.paper, in: RoundedRectangle(cornerRadius: 8))
    }
    private var remoteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("相手").kikimimiText(.heading)
            VStack(alignment: .leading, spacing: 8) {
                Text("音声を録音するアプリ").kikimimiText(.label)
                Picker("音声を録音するアプリ", selection: $selection) {
                    Text("選択してください").tag("")
                    ForEach(candidates, id: \.selectionID) { source in Text(source.label).tag(source.selectionID) }
                }
                .pickerStyle(.menu).labelsHidden().kikimimiField().disabled(starting)
            }
            if selectedSource == .allSystemAudio {
                Text("通知など、他のアプリの音も録音されます").kikimimiText(.small).foregroundStyle(KikimimiColor.warning)
            } else {
                Text("このアプリの音だけを録音します。\n別のアプリや通知の音は含みません。")
                    .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
            }
            Text("相手の入力確認は録音開始後に行います。")
                .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(KikimimiColor.paper, in: RoundedRectangle(cornerRadius: 8))
    }
    private var microphoneLabel: String {
        guard let mic = env.settings.settings.mic else { return "マイクを選択してください" }
        return "\(mic.deviceName) / \(mic.channel.map { "INPUT \($0)" } ?? "全チャンネル")"
    }
    private var selectedSource: RemoteSource? { candidates.first { $0.selectionID == selection } }
    private var startDisabled: Bool {
        starting || company.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedSource == nil ||
            !env.readiness.readiness.canRecord || env.recorder.phase.isCapturing || env.termination.requested
    }
    private var previewKey: String {
        let mic = env.settings.settings.mic
        let device = devices.first { $0.uid == mic?.deviceUID }
        return "\(visible)/\(scenePhase)/\(starting)/\(env.recorder.phase.isCapturing)/\(env.readiness.readiness.mic)/\(mic?.deviceUID ?? "")/\(mic?.channel ?? 0)/\(device?.inputChannels ?? 0)"
    }
    private func preview() async {
        level = nil
        previewFailed = false
        guard visible, scenePhase == .active, !starting, !env.recorder.phase.isCapturing,
              env.readiness.readiness.mic == .authorized, let choice = env.settings.settings.mic,
              let device = devices.first(where: { $0.uid == choice.deviceUID }) else { return }
        previewError = nil
        previewing = true
        defer { previewing = false }
        do {
            let values = try await env.microphoneLevels(device: device, channel: choice.channel)
            for try await value in values {
                guard !Task.isCancelled else { break }
                level = value
            }
        } catch is CancellationError {} catch {
            if !Task.isCancelled { previewFailed = true; previewError = "入力の確認に失敗しました: \(error.localizedDescription)" }
        }
    }
    private func showRecordingSettings() {
        UserDefaults.standard.set(SettingsPane.recording.rawValue, forKey: "settings.selectedPane")
        openSettings()
    }
    private func start() {
        guard !startDisabled, let source = selectedSource else { return }
        let task = previewTask
        starting = true; error = nil
        task?.cancel()
        Task {
            await task?.value
            defer { starting = false }
            let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try await env.recorder.start(.init(company: company, title: label.isEmpty ? nil : label,
                                                   remote: source, event: event.map(SessionEvent.init)))
                env.settings.settings.remote = source
                // MainWindowView observes the new ref and replaces the prepare route after listing refresh.
            } catch { self.error = "録音を開始できませんでした: \(error)" }
        }
    }
}

private extension RemoteSource {
    var selectionID: String {
        switch self { case .app(let id, _): id; case .allSystemAudio: "all-system-audio" }
    }
    var label: String {
        switch self { case .app(_, let name): name; case .allSystemAudio: "全システム音" }
    }
}
