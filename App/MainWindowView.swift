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
                    ForEach(orderedSessions) { session in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.company).font(.headline).lineLimit(1)
                            if let title = session.title { Text(title).lineLimit(1) }
                            Text(session.startedAt, format: .dateTime.year().month().day().hour().minute())
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
                .overlay {
                    if sessions.isEmpty, listError == nil {
                        Text("録音はまだありません").foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("録音")
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
            } detail: {
                if let session = sessions.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(session.company).font(.largeTitle.bold())
                        if let title = session.title { Text(title).font(.title2) }
                        Text(session.state.label).foregroundStyle(.secondary)
                        if case .recording(let recording) = env.recorder.phase, recording.ref.id == session.id {
                            HStack { Text("録音中"); Text(recording.startedAt, style: .timer).monospacedDigit() }
                            TrackMeter(label: "自分", peak: env.recorder.levels?.me, health: recording.health.me)
                            TrackMeter(label: "相手", peak: env.recorder.levels?.remote, health: recording.health.remote)
                            Button("録音を停止") { Task { await env.recorder.stop() } }
                        }
                        Spacer()
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
