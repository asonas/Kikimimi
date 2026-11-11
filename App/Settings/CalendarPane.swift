import AppKit
import SwiftUI

struct CalendarPane: View {
    let env: AppEnvironment
    var body: some View {
        SettingsPage("カレンダー", description: "予定を表示して、面接の録音を準備しやすくします。") {
            SettingsSection("カレンダーへのアクセス") {
                SettingsRow("アクセス", description: "許可しなくても録音できます。") {
                    switch env.calendar.access {
                    case .notDetermined:
                        Button("アクセスを許可") { Task { await env.calendar.requestAccess(calendars: env.settings.settings.calendarIDs) } }
                            .disabled(env.calendar.requesting)
                    case .denied:
                        Button("システム設定を開く") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
                        }
                    case .restricted: SettingsStatus(text: "アクセスが制限されています", ready: false)
                    case .authorized: SettingsStatus(text: "許可済み")
                    }
                }
            }
            if env.calendar.access == .authorized {
                SettingsSection("表示するカレンダー") {
                    if env.calendar.calendars.isEmpty {
                        SettingsRow("カレンダーがありません", description: "カレンダーアプリのアカウント設定を確認してください") { EmptyView() }
                    }
                    ForEach(Array(env.calendar.calendars.enumerated()), id: \.element.id) { index, calendar in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(calendar.title, description: calendar.source) {
                            Toggle(isOn: Binding(get: { isEnabled(calendar.id) }, set: { enabled in setEnabled(enabled, id: calendar.id) })) {
                                Text(isEnabled(calendar.id) ? "表示する" : "表示しない")
                            }
                            .toggleStyle(.switch).tint(KikimimiColor.ink).frame(minHeight: 40).fixedSize()
                            .accessibilityLabel("\(calendar.title)を表示")
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button("すべて表示") { env.settings.settings.calendarIDs = nil }
                    Button("すべて非表示") { env.settings.settings.calendarIDs = [] }
                }
            }
            Text("アカウントの追加や変更は、macOSのカレンダーで行います。")
                .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
        }
    }
    private func isEnabled(_ id: String) -> Bool { env.settings.settings.calendarIDs?.contains(id) ?? true }
    private func setEnabled(_ enabled: Bool, id: String) {
        var selected = env.settings.settings.calendarIDs ?? Set(env.calendar.calendars.map(\.id))
        if enabled { selected.insert(id) } else { selected.remove(id) }
        env.settings.settings.calendarIDs = selected
    }
}
