import SwiftUI
import RecorderCore

struct CalendarSettingsView: View {
    let env: AppEnvironment
    let openPrivacy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("カレンダー").font(.headline)
            Text("予定の表示に使います。許可しなくても録音できます")
                .font(.caption).foregroundStyle(.secondary)
            switch env.calendar.access {
            case .notDetermined:
                Button("アクセスを許可") {
                    Task { await env.calendar.requestAccess(calendars: env.settings.settings.calendarIDs) }
                }
                .disabled(env.calendar.requesting)
            case .denied:
                Text("カレンダーへのアクセスが許可されていません").font(.subheadline)
                Button("システム設定を開く", action: openPrivacy)
            case .restricted:
                Text("カレンダーへのアクセスが制限されています").font(.subheadline)
            case .authorized:
                Text("アクセス許可済み").font(.subheadline).foregroundStyle(.secondary)
                if env.calendar.calendars.isEmpty {
                    Text("カレンダーがありません。カレンダーアプリのアカウント設定を確認してください")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(sources, id: \.self) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source).font(.caption).foregroundStyle(.secondary)
                        ForEach(env.calendar.calendars.filter { $0.source == source }) { calendar in
                            Toggle(calendar.title, isOn: Binding(get: {
                                env.settings.settings.calendarIDs?.contains(calendar.id) ?? true
                            }, set: { enabled in
                                var selected = env.settings.settings.calendarIDs ?? Set(env.calendar.calendars.map(\.id))
                                if enabled { selected.insert(calendar.id) } else { selected.remove(calendar.id) }
                                env.settings.settings.calendarIDs = selected
                            }))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
    }

    private var sources: [String] { Set(env.calendar.calendars.map(\.source)).sorted() }
}
