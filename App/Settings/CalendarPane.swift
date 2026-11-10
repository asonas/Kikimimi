import AppKit
import SwiftUI

struct CalendarPane: View {
    let env: AppEnvironment
    var body: some View {
        Form {
            Section {
                LabeledContent("アクセス") {
                    switch env.calendar.access {
                    case .notDetermined:
                        Button("アクセスを許可") {
                            Task {
                                await env.calendar.requestAccess(
                                    calendars: env.settings.settings.calendarIDs)
                            }
                        }
                        .disabled(env.calendar.requesting)
                    case .denied:
                        Text("未許可")
                        Button("システム設定を開く") {
                            if let url = URL(
                                string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                            ) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    case .restricted: Text("アクセスが制限されています")
                    case .authorized: Text("許可済み")
                    }
                }
                if env.calendar.access == .authorized, env.calendar.calendars.isEmpty {
                    Text("カレンダーがありません。カレンダーアプリのアカウント設定を確認してください")
                }
            } header: {
                Text("アクセス")
            } footer: {
                Text("予定の表示に使います。許可しなくても録音できます。")
            }
            if env.calendar.access == .authorized {
                ForEach(sources, id: \.self) { source in
                    Section {
                        ForEach(env.calendar.calendars.filter { $0.source == source }) { calendar in
                            Toggle(
                                calendar.title,
                                isOn: Binding(
                                    get: {
                                        env.settings.settings.calendarIDs?.contains(calendar.id)
                                            ?? true
                                    }, set: { enabled in setEnabled(enabled, ids: [calendar.id]) })
                            )
                            .toggleStyle(.switch)
                        }
                    } header: {
                        HStack {
                            Text(source)
                            Spacer()
                            Menu("選択") {
                                Button("すべてオン") { setSource(source, enabled: true) }
                                Button("すべてオフ") { setSource(source, enabled: false) }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel("\(source)のカレンダー選択")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    private var sources: [String] { Set(env.calendar.calendars.map(\.source)).sorted() }
    private func setSource(_ source: String, enabled: Bool) {
        setEnabled(
            enabled, ids: Set(env.calendar.calendars.filter { $0.source == source }.map(\.id)))
    }
    private func setEnabled(_ enabled: Bool, ids: Set<String>) {
        var selected = env.settings.settings.calendarIDs ?? Set(env.calendar.calendars.map(\.id))
        if enabled { selected.formUnion(ids) } else { selected.subtract(ids) }
        env.settings.settings.calendarIDs = selected
    }
}
