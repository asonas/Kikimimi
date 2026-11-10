import AppKit
import SwiftUI
import RecorderCore

struct MainWindowView: View {
    let env: AppEnvironment
    @Environment(\.openSettings) private var openSettings
    @State private var sessions: [SessionListing] = []
    @State private var selection: UUID?
    @State private var listError: String?
    @State private var recordingRequest: RecordingRequest?
    @State private var detailState: SessionDetailState?

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
                sidebar
            } content: {
                if let session = selectedSession, let detailState, detailState.ref == session.ref {
                    SessionDetailView(env: env, session: session, state: detailState).id(session.id)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 420)
                } else {
                    Color.clear.navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 420)
                }
            } detail: {
                if let session = selectedSession {
                    if let detailState, detailState.ref == session.ref {
                        SessionDocumentView(env: env, state: detailState).id(session.id)
                    } else {
                        ProgressView("録音情報を読み込んでいます")
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                        Text("録音を選択してください").font(.title2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 1100, minHeight: 620)
        .toolbar {
            Button { recordingRequest = RecordingRequest(event: nil) } label: { Label("新しい録音", systemImage: "plus") }
                .disabled(recordingUnavailable)
        }
        .sheet(item: $recordingRequest) { NewRecordingView(env: env, event: $0.event) }
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
        .task(id: selectedSession?.ref) {
            guard let session = selectedSession else { detailState = nil; return }
            let state = SessionDetailState(ref: session.ref)
            detailState = state
            while !Task.isCancelled {
                await state.refresh(store: env.store)
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .onChange(of: activeSessionID) { _, id in
            if let id { selection = id; Task { await refresh() } }
        }
    }

    private var sidebar: some View {
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
                                Spacer(minLength: 4)
                                Button("録音") { recordingRequest = RecordingRequest(event: event) }
                                    .controlSize(.small)
                                    .disabled(recordingUnavailable)
                                    .accessibilityLabel("\(event.title)の録音を準備")
                            }
                        }
                        .padding(.vertical, 4)
                        .selectionDisabled()
                    }
                }
            }
            Section("録音") {
                ForEach(orderedSessions) { session in
                    recordingRow(session).tag(session.id)
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
    }

    private func refreshCalendar() { env.calendar.refresh(calendars: env.settings.settings.calendarIDs) }

    private var selectedSession: SessionListing? { sessions.first { $0.id == selection } }

    private func recordingRow(_ session: SessionListing) -> some View {
        let status = job(for: session)?.label ?? session.state.label
        return VStack(alignment: .leading, spacing: 6) {
            Text(session.company).font(.headline).lineLimit(1)
            if let title = session.title { Text(title).lineLimit(1) }
            Text(SessionDate.string(session.startedAt))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(status)
                    .font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                if let duration = session.durationSeconds {
                    Text(Duration.seconds(duration), format: .time(pattern: .hourMinuteSecond))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var recordingUnavailable: Bool {
        !env.readiness.readiness.canRecord || env.recorder.phase.isCapturing || env.termination.requested
    }

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

private struct RecordingRequest: Identifiable {
    let id = UUID()
    let event: CalendarEvent?
}
