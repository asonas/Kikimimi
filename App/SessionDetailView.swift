import AppKit
import SwiftUI
import RecorderCore

struct SessionDetailView: View {
    let env: AppEnvironment
    let session: SessionListing
    @Environment(\.openSettings) private var openSettings
    @State private var meta: SessionMeta?
    @State private var metadataError: String?
    @State private var transcript: TranscriptDisplay = .loading
    @State private var markdownAvailable = false
    @State private var copyMessage: String?
    @State private var segmentsAvailable = false
    @State private var exporting = false
    @State private var exportError: String?
    @State private var exportOutdated = false

    private enum TranscriptDisplay: Equatable {
        case loading, absent, loaded([TranscriptLine]), failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let metadataError { Text(metadataError).foregroundStyle(.red) }
                liveCapture
                if let meta {
                    HStack(alignment: .top, spacing: 24) {
                        trackSummary(.me, meta: meta)
                        trackSummary(.remote, meta: meta)
                    }
                }
                actions
                exportStatus
                jobProgress
                if let copyMessage { Text(copyMessage).font(.caption).foregroundStyle(.secondary) }
                Divider()
                SessionSummaryView(env: env, ref: session.ref, transcriptAvailable: markdownAvailable)
                Divider()
                Text("書き起こし").font(.title2.bold())
                transcriptContent
            }
            .padding(32)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: session.ref) {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.company).font(.largeTitle.bold()).textSelection(.enabled)
            if let title = session.title { Text(title).font(.title2).textSelection(.enabled) }
            HStack(spacing: 16) {
                Text(SessionDate.string(session.startedAt, timeZone: meta.flatMap { TimeZone(identifier: $0.timeZone) }))
                if let seconds = session.durationSeconds {
                    Text(Duration.seconds(seconds), format: .time(pattern: .hourMinuteSecond)).monospacedDigit()
                }
                Text(job?.label ?? session.state.label)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: Capsule())
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var liveCapture: some View {
        if case .recording(let recording) = env.recorder.phase, recording.ref.id == session.id {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("録音中", systemImage: "record.circle.fill").foregroundStyle(.red)
                    Text(recording.startedAt, style: .timer).monospacedDigit()
                    Spacer()
                    Button("録音を停止") { Task { await env.recorder.stop() } }
                }
                TrackMeter(label: "自分", peak: env.recorder.levels?.me, health: recording.health.me)
                TrackMeter(label: "相手", peak: env.recorder.levels?.remote, health: recording.health.remote)
            }
            .padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        } else if case .stopping(let stopping) = env.recorder.phase, stopping.ref.id == session.id {
            ProgressView("録音を保存しています")
        } else if session.state == .capturing {
            Label("別のアプリで録音中です", systemImage: "record.circle")
        }
    }

    private func trackSummary(_ track: Track, meta: SessionMeta) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(track == .me ? "自分" : "相手", systemImage: track == .me ? "mic" : "speaker.wave.2")
                .font(.subheadline.bold())
            if let value = meta.tracks[track] {
                Text(value.source.displayName).font(.caption).foregroundStyle(.secondary)
                if let failure = value.failure {
                    Text("入力の停止: \(failure.message)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                } else if let audio = value.audio {
                    Text(audio.isEffectivelySilent ? "無音のため書き起こしを省略" : "音声を保存済み")
                        .font(.caption).foregroundStyle(audio.isEffectivelySilent ? .orange : .secondary)
                } else {
                    Text(session.state == .capturing ? "録音中" : "音声は未保存").font(.caption).foregroundStyle(.secondary)
                }
                if let audio = value.audio {
                    Text(String(format: "%.1f 秒 · peak %.1f dBFS", audio.durationSeconds, audio.peakDBFS))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else {
                Text("音声なし").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actionButtons }
            VStack(alignment: .leading, spacing: 12) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        if session.state == .readyToTranscribe || session.state == .transcribed {
            Button(session.state == .transcribed ? "再書き起こし" : "文字起こし") {
                copyMessage = nil
                env.transcription.enqueue(session.ref)
            }
            .buttonStyle(.borderedProminent)
            .disabled(job?.isBusy == true || env.termination.requested)
        }
        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([session.ref.folder.url]) }
        Button("Markdown をコピー") { copyMarkdown() }.disabled(!markdownAvailable)
        if let path = env.settings.settings.exportFolder {
            Button("ノートを書き出す") { exportNote(to: path) }
                .disabled(!segmentsAvailable || exporting || env.termination.requested)
        } else {
            Button("書き出し先を設定") { openSettings() }
        }
    }

    @ViewBuilder private var exportStatus: some View {
        if let exported = meta?.export {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(exported.path) に書き出しました（\(SessionDate.string(exported.at))）")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("書き出したノートを Finder で表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exported.path)])
                }
                .font(.caption)
                if exportOutdated {
                    Text("書き出し後に書き起こしか要約が更新されています").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        if let exportError { Text(exportError).foregroundStyle(.red).textSelection(.enabled) }
    }

    private func exportNote(to path: String) {
        guard !exporting else { return }
        exporting = true; exportError = nil
        Task {
            defer { exporting = false }
            do {
                try await env.store.exportNote(session.ref, to: URL(fileURLWithPath: path, isDirectory: true))
                await refresh()
            } catch { exportError = "書き出せませんでした: \(error.localizedDescription)" }
        }
    }

    @ViewBuilder private var jobProgress: some View {
        switch job {
        case .running(let fraction): ProgressView("文字起こし中 \(Int(fraction * 100))%", value: fraction)
        case .queued, .waiting: Label(job?.label ?? "文字起こし待ち", systemImage: "clock")
        case .failed(let message): Text("文字起こしに失敗しました: \(message)").foregroundStyle(.red).textSelection(.enabled)
        default: EmptyView()
        }
    }

    @ViewBuilder private var transcriptContent: some View {
        switch transcript {
        case .loading: ProgressView("書き起こしを読み込んでいます")
        case .absent:
            Text("書き起こしはまだありません").foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("書き起こしを読み込めませんでした").foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .loaded(let lines):
            if lines.isEmpty {
                Text("表示する発話はありません").foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(line.timestamp).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(line.speaker == .me ? "自分" : "相手")
                                    .font(.caption.bold()).foregroundStyle(line.speaker == .me ? .blue : .purple)
                            }
                            .frame(width: 76, alignment: .leading)
                            Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 16)
                        Divider()
                    }
                }
            }
        }
    }

    private var job: TranscriptionJobState? { env.transcription.jobs.first { $0.id == session.id }?.state }

    private func refresh() async {
        do {
            let value = try await env.store.meta(of: session.ref)
            guard !Task.isCancelled else { return }
            meta = value; metadataError = nil
        } catch { if !Task.isCancelled { metadataError = "録音情報を読み込めませんでした: \(error.localizedDescription)" } }
        do {
            let lines = try await env.store.transcriptLines(of: session.ref)
            guard !Task.isCancelled else { return }
            transcript = lines.map(TranscriptDisplay.loaded) ?? .absent
            segmentsAvailable = lines != nil
        } catch { if !Task.isCancelled { transcript = .failed(error.localizedDescription); segmentsAvailable = false } }
        markdownAvailable = FileManager.default.fileExists(atPath: session.ref.folder.transcript.path)
        if let exported = meta?.export {
            let dates = [session.ref.folder.transcript, session.ref.folder.summary].compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            exportOutdated = SessionExportFreshness.isOutdated(exportedAt: exported.at, modifiedAt: dates)
        } else { exportOutdated = false }
    }

    private func copyMarkdown() {
        do {
            let markdown = try String(contentsOf: session.ref.folder.transcript, encoding: .utf8)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(markdown, forType: .string) else {
                copyMessage = "クリップボードに書き込めませんでした"; return
            }
            copyMessage = "Markdown をコピーしました"
        } catch { copyMessage = "Markdown を読み込めませんでした: \(error.localizedDescription)" }
    }
}

private extension TrackSource {
    var displayName: String {
        switch self {
        case .mic(_, let name, let channel, _): name + (channel.map { " · INPUT \($0)" } ?? " · 全チャンネル")
        case .app(_, let name): name
        case .allSystemAudio: "全システム音"
        }
    }
}
