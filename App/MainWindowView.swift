import AppKit
import SwiftUI
import RecorderCore

struct MainWindowView: View {
    let env: AppEnvironment
    @Environment(\.openSettings) private var openSettings
    @State private var sessions: [SessionListing] = []
    @State private var listError: String?

    var body: some View {
        @Bindable var navigation = env.navigation
        NavigationStack(path: $navigation.path) {
            recordingList
                .navigationDestination(for: MainRoute.self) { route in
                    switch route {
                    case .prepare(let event):
                        PrepareRecordingView(env: env, event: event)
                            .navigationBarBackButtonHidden()
                    case .session(let ref):
                        if let session = sessions.first(where: { $0.ref == ref }) {
                            SessionDetailView(env: env, session: session).id(ref)
                                .navigationBarBackButtonHidden()
                        } else {
                            Text("録音が見つかりません").kikimimiText(.body)
                                .navigationBarBackButtonHidden()
                        }
                    }
                }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(RecorderWindowCapture { env.recorderWindows.captureMain($0) }.frame(width: 0, height: 0))
        .foregroundStyle(KikimimiColor.ink)
        .background(KikimimiColor.surface)
        .tint(KikimimiColor.ink)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if env.navigation.path.isEmpty {
                    HStack(spacing: 12) {
                        Image("Ear").renderingMode(.template).resizable().frame(width: 32, height: 32)
                            .accessibilityHidden(true)
                        Text("Kikimimi").kikimimiText(.heading)
                    }
                } else {
                    Button { env.navigation.showList() } label: { Label("録音一覧", systemImage: "chevron.left") }
                        .buttonStyle(KikimimiButtonStyle.text)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { openSettings() } label: { Label("設定", systemImage: "gearshape") }
                    .buttonStyle(KikimimiButtonStyle.text)
            }
        }
        .toolbarBackground(KikimimiColor.paper, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .task { refreshCalendar() }
        .onChange(of: env.settings.settings.calendarIDs) { _, _ in refreshCalendar() }
        .onReceive(NotificationCenter.default.publisher(for: LiveCalendar.changedNotification).receive(on: RunLoop.main)) { _ in refreshCalendar() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshCalendar() }
        .task {
            await env.launched.value
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .onChange(of: activeSessionRef, initial: true) { _, ref in
            guard let ref else { return }
            Task { await refresh(); env.navigation.showSession(ref) }
        }
    }

    private var recordingList: some View {
        MainPage {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("録音").kikimimiText(.title)
                    Text("会話の記録を、ここから。").kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                }
                Spacer()
                Button("新しい録音") { env.navigation.prepare() }
                    .buttonStyle(KikimimiButtonStyle.primary).disabled(recordingUnavailable)
            }
            if !env.readiness.readiness.canRecord {
                HStack(spacing: 16) {
                    Text("録音を始めるには設定で準備を完了してください").kikimimiText(.label)
                        .foregroundStyle(KikimimiColor.warning)
                    Spacer()
                    Button("設定を開く") { openSettings() }.buttonStyle(KikimimiButtonStyle.secondary)
                }
                .padding(16).background(KikimimiColor.warningBg, in: RoundedRectangle(cornerRadius: 8))
            }
            if env.calendar.access == .authorized, !env.calendar.events.isEmpty { upcomingEvents }
            VStack(spacing: 12) {
                HStack {
                    Text("これまでの録音").kikimimiText(.heading)
                    Spacer()
                    Text("新しい順").kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                }
                LazyVStack(spacing: 0) {
                    ForEach(sessions) { session in
                        RecordingListRow(session: session, job: job(for: session), localCapture: env.localCapture(for: session.ref)) {
                            env.navigation.showSession(session.ref)
                        }
                        MainDivider()
                    }
                }
                if sessions.isEmpty, listError == nil {
                    Text("録音はまだありません。新しい録音から始められます。")
                        .kikimimiText(.body).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let listError { Text(listError).foregroundStyle(KikimimiColor.danger).textSelection(.enabled) }
            }
            HStack {
                Text("録音と文字起こしは、このMacに保存されます。")
                Spacer()
                Text("\(sessions.count)件の録音")
            }
            .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
        }
    }

    private var upcomingEvents: some View {
        VStack(spacing: 12) {
            HStack {
                Text("これからの予定").kikimimiText(.heading)
                Spacer()
                Text("カレンダーから表示").kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
            }
            VStack(spacing: 0) {
                ForEach(env.calendar.events) { event in
                    HStack(spacing: 20) {
                        Text(SessionDate.upcoming(start: event.start, end: event.end))
                            .kikimimiText(.number).foregroundStyle(KikimimiColor.secondary)
                            .frame(width: 190, alignment: .leading)
                        Text(event.title).kikimimiText(.label).frame(maxWidth: .infinity, alignment: .leading)
                        Button("録音を準備") { env.navigation.prepare(event: event) }
                            .buttonStyle(KikimimiButtonStyle.secondary).disabled(recordingUnavailable)
                    }
                    if event.id != env.calendar.events.last?.id { MainDivider() }
                }
            }
        }
        .padding(24).background(KikimimiColor.paper, in: RoundedRectangle(cornerRadius: 8))
    }

    private var recordingUnavailable: Bool {
        !env.readiness.readiness.canRecord || env.recorder.phase.isCapturing || env.termination.requested
    }
    private var activeSessionRef: SessionRef? {
        switch env.recorder.phase {
        case .recording(let recording): recording.ref
        case .stopping(let stopping): stopping.ref
        default: nil
        }
    }
    private func job(for session: SessionListing) -> TranscriptionJobState? {
        env.transcription.jobs.first { $0.id == session.id }?.state
    }
    private func refreshCalendar() { env.calendar.refresh(calendars: env.settings.settings.calendarIDs) }
    private func refresh() async {
        do {
            let value = try await env.store.list()
            guard !Task.isCancelled else { return }
            sessions = value; listError = nil
        } catch { if !Task.isCancelled { listError = "録音一覧を取得できませんでした: \(error.localizedDescription)" } }
    }
}
