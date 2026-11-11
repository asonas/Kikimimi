import AppKit
import RecorderCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case recording, transcription, calendar, summary, export
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recording: "録音"
        case .transcription: "文字起こし"
        case .calendar: "カレンダー"
        case .summary: "要約"
        case .export: "書き出し"
        }
    }
    var description: String {
        switch self {
        case .recording: "マイクと音声の許可"
        case .transcription: "このMacで処理"
        case .calendar: "予定を表示"
        case .summary: "ChatGPT・APIキー"
        case .export: "ノートの保存先"
        }
    }
}

struct SetupView: View {
    let env: AppEnvironment
    @AppStorage("settings.selectedPane") private var selected = SettingsPane.recording.rawValue
    @State private var lastLoggedRows: String?
    private var pane: SettingsPane { SettingsPane(rawValue: selected) ?? .recording }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("設定").kikimimiText(.heading).padding(24)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(SettingsPane.allCases) { item in
                            Button { selected = item.rawValue } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(item.title).kikimimiText(.label)
                                        Spacer()
                                        if item == .recording, !env.readiness.readiness.canRecord {
                                            Circle().fill(KikimimiColor.danger).frame(width: 7, height: 7)
                                                .accessibilityLabel("録音の準備が必要です")
                                        }
                                    }
                                    Text(item.description).kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(pane == item ? KikimimiColor.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(KikimimiButtonStyle.text)
                            .accessibilityAddTraits(pane == item ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 8)
                }
                Spacer(minLength: 16)
                Text("Kikimimi").kikimimiText(.small).foregroundStyle(KikimimiColor.secondary).padding(24)
            }
            .foregroundStyle(KikimimiColor.ink)
            .background(KikimimiColor.paper)
            .navigationSplitViewColumnWidth(min: 248, ideal: 248, max: 248)
        } detail: {
            Group {
                switch pane {
                case .recording: RecordingPane(env: env)
                case .transcription: TranscriptionPane(env: env)
                case .calendar: CalendarPane(env: env)
                case .summary: SummaryPane(env: env)
                case .export: ExportPane(env: env)
                }
            }
            .background(KikimimiColor.surface)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(KikimimiColor.ink)
        .frame(minWidth: 880, idealWidth: 1040, minHeight: 600, idealHeight: 720)
        .task {
            refreshCalendar()
            env.summaryCredentials.refresh()
            await env.chatGPT.refresh()
        }
        .onChange(of: env.settings.settings.calendarIDs) { _, _ in refreshCalendar() }
        .onReceive(
            NotificationCenter.default.publisher(for: LiveCalendar.changedNotification).receive(
                on: RunLoop.main)
        ) { _ in refreshCalendar() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in refreshCalendar() }
        .task {
            await env.launched.value
            while !Task.isCancelled {
                await env.readiness.refresh()
                logRows()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    private func refreshCalendar() {
        env.calendar.refresh(calendars: env.settings.settings.calendarIDs)
    }
    private func logRows() {
        #if DEBUG
            let screen = env.readiness.readiness.screen
            let mic = env.readiness.readiness.mic
            let line =
                "SETUP screen=\(screen) microphone=\(mic) input=\(env.readiness.readiness.micDevice) model=\(env.transcription.model) variant=\(env.modelVariant) override=\(env.modelVariantOverridden)"
            if line != lastLoggedRows {
                lastLoggedRows = line
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        #endif
    }
}
