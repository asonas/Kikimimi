import AppKit
import RecorderCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case recording, transcription, calendar, summary, export
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recording: "録音"
        case .transcription: "書き起こし"
        case .calendar: "カレンダー"
        case .summary: "要約"
        case .export: "書き出し"
        }
    }
    var symbol: String {
        switch self {
        case .recording: "record.circle"
        case .transcription: "waveform"
        case .calendar: "calendar"
        case .summary: "sparkles"
        case .export: "square.and.arrow.up"
        }
    }
    var color: Color {
        switch self {
        case .recording: .red
        case .transcription: .blue
        case .calendar: .orange
        case .summary: .purple
        case .export: .green
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
            List(
                selection: Binding<SettingsPane?>(
                    get: { pane }, set: { if let value = $0 { selected = value.rawValue } })
            ) {
                ForEach(SettingsPane.allCases) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(item.color, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            Text(subtitle(item)).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 3).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
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
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 440, idealHeight: 520)
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
    private func subtitle(_ pane: SettingsPane) -> String {
        switch pane {
        case .recording: return env.readiness.readiness.canRecord ? "準備完了" : "要対応"
        case .transcription:
            switch env.transcription.model {
            case .ready: return "インストール済み"
            case .downloading(let fraction): return "ダウンロード中 \(Int(fraction * 100))%"
            case .optimizing: return "最適化中"
            case .notInstalled: return "未インストール"
            case .failed: return "導入失敗"
            }
        case .calendar:
            return env.calendar.access == .authorized
                ? "許可済み・\(env.calendar.calendars.count) 件のカレンダー" : "未許可"
        case .summary:
            if env.settings.settings.summaryProvider == .chatGPT {
                return env.chatGPT.signedIn ? "ChatGPT: \(env.chatGPT.email ?? "サインイン済み")" : "未設定"
            }
            return env.summaryCredentials.hasKey ? "API キー" : "未設定"
        case .export:
            return env.settings.settings.exportFolder.map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
                ?? "未設定"
        }
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
