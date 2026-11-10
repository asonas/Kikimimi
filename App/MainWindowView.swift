import AppKit
import SwiftUI
import RecorderCore

struct MainWindowView: View {
    let env: AppEnvironment
    @Environment(\.openSettings) private var openSettings
    @State private var sessions: [SessionListing] = []
    @State private var selection: UUID?
    @State private var listError: String?
    @State private var presentingRecording = false

    var body: some View {
        VStack(spacing: 0) {
            if !env.readiness.readiness.canRecord {
                HStack {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text("録音を始めるには設定で準備を完了してください")
                    Spacer()
                    Button("設定を開く") { openSettings() }
                }
                .padding(12)
                .background(.quaternary)
            }
            NavigationSplitView {
                List(selection: $selection) {
                    if env.calendar.access == .authorized, !env.calendar.events.isEmpty {
                        Section("これからの予定") {
                            ForEach(env.calendar.events) { event in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(SessionDate.range(start: event.start, end: event.end))
                                        .font(.caption).foregroundStyle(.secondary)
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(event.title).lineLimit(2)
                                        if event.meetingURL != nil {
                                            Image(systemName: "video").font(.caption)
                                                .accessibilityLabel("オンライン会議リンクあり")
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                                .selectionDisabled()
                            }
                        }
                    }
                    Section("録音") {
                        ForEach(orderedSessions) { session in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.company).font(.headline).lineLimit(1)
                                if let title = session.title { Text(title).lineLimit(1) }
                                Text(SessionDate.string(session.startedAt))
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Text(job(for: session)?.label ?? session.state.label)
                                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(.quaternary, in: Capsule())
                                    if let duration = session.durationSeconds {
                                        Text(Duration.seconds(duration), format: .time(pattern: .hourMinuteSecond))
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                            .tag(session.id)
                        }
                        if let listError { Text(listError).foregroundStyle(.red) }
                    }
                }
                .overlay {
                    if sessions.isEmpty, listError == nil, env.calendar.events.isEmpty {
                        Text("録音はまだありません").foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("録音")
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
            } detail: {
                if let session = sessions.first(where: { $0.id == selection }) {
                    SessionDetailView(env: env, session: session).id(session.id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                        Text("録音を選択してください").font(.title2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            Button { presentingRecording = true } label: { Label("新しい録音", systemImage: "plus") }
                .disabled(env.recorder.phase.isCapturing || env.termination.requested)
        }
        .sheet(isPresented: $presentingRecording) { NewRecordingView(env: env) }
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
        .onChange(of: activeSessionID) { _, id in
            if let id { selection = id; Task { await refresh() } }
        }
    }

    private func refreshCalendar() { env.calendar.refresh(calendars: env.settings.settings.calendarIDs) }

    private var activeSessionID: UUID? {
        switch env.recorder.phase {
        case .recording(let recording): recording.ref.id
        case .stopping(let stopping): stopping.ref.id
        default: nil
        }
    }

    private var orderedSessions: [SessionListing] {
        sessions.filter { $0.state == .capturing } + sessions.filter { $0.state != .capturing }
    }

    private func job(for session: SessionListing) -> TranscriptionJobState? {
        env.transcription.jobs.first { $0.id == session.id }?.state
    }

    private func refresh() async {
        do {
            sessions = try await env.store.list()
            listError = nil
            if selection == nil { selection = activeSessionID ?? orderedSessions.first?.id }
        } catch { listError = "録音一覧を取得できませんでした: \(error.localizedDescription)" }
    }
}
