import AppKit
import SwiftUI
import RecorderCore

struct SessionDetailView: View {
    let env: AppEnvironment
    let session: SessionListing
    @State private var state: SessionDetailState
    @Environment(\.openSettings) private var openSettings
    @State private var showingInfo = false
    @State private var copied = false
    @State private var exporting = false
    @State private var actionError: String?

    init(env: AppEnvironment, session: SessionListing) {
        self.env = env; self.session = session
        _state = State(initialValue: SessionDetailState(ref: session.ref))
    }

    var body: some View {
        MainPage {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.company).kikimimiText(.title).textSelection(.enabled)
                Text(subtitle).kikimimiText(.small).foregroundStyle(KikimimiColor.secondary).monospacedDigit()
            }
            if let error = state.metadataError { Text(error).foregroundStyle(KikimimiColor.danger).textSelection(.enabled) }
            if page == .document {
                documentActions
                documentTabs
                MainDivider()
                switch state.tab {
                case .transcript: SessionTranscriptView(display: state.transcript)
                case .summary: SessionSummaryView(env: env, ref: session.ref, transcriptAvailable: state.markdownAvailable)
                }
                exportStatus
            } else {
                SessionActivityView(env: env, session: session, state: state, job: job)
                if page == .needsAttention {
                    Button("録音の情報") { showingInfo = true }.buttonStyle(KikimimiButtonStyle.text)
                }
            }
            if let actionError { Text(actionError).foregroundStyle(KikimimiColor.danger).textSelection(.enabled) }
        }
        .sheet(isPresented: $showingInfo) {
            SessionInfoSheet(env: env, session: session, state: state, job: job)
        }
        .sheet(isPresented: $copied) {
            MainSheet {
                SettingsStatus(text: "Markdownをコピーしました", showsDot: true)
                Text("文字起こしをコピーしました。\nメモや文書に貼り付けて使えます。")
                    .kikimimiText(.body).foregroundStyle(KikimimiColor.secondary)
                Button("文字起こしに戻る") { state.tab = .transcript; copied = false }
                    .buttonStyle(KikimimiButtonStyle.primary)
            }
        }
        .task(id: session.ref) {
            while !Task.isCancelled {
                await state.refresh(store: env.store)
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .onChange(of: env.summaryJobs.jobs[session.ref]) { _, value in
            if case .finished = value { state.tab = .summary }
        }
    }

    private var page: SessionPage { .resolve(state: session.state, job: job, localCapture: env.localCapture(for: session.ref)) }
    private var job: TranscriptionJobState? { env.transcription.jobs.first { $0.id == session.id }?.state }
    private var subtitle: String {
        if page == .recording {
            return [session.title, SessionDate.formatted(session.startedAt, "yyyy年M月d日", timeZone: state.meta.flatMap { TimeZone(identifier: $0.timeZone) })]
                .compactMap { $0 }.joined(separator: "  /  ")
        }
        return [session.title, SessionDate.detail(session.startedAt, timeZone: state.meta.flatMap { TimeZone(identifier: $0.timeZone) }),
         session.durationSeconds.map(SessionDate.duration)].compactMap { $0 }.joined(separator: "  /  ")
    }
    private var documentActions: some View {
        HStack(spacing: 12) {
            SettingsStatus(text: session.hasSummary ? "要約を作成済み" : "文字起こし済み", showsDot: true)
            Spacer()
            if state.tab == .transcript {
                Button("Markdownをコピー", action: copyMarkdown).buttonStyle(KikimimiButtonStyle.secondary)
                    .disabled(!state.markdownAvailable)
            }
            if let path = env.settings.settings.exportFolder {
                Button("ノートを書き出す") { exportNote(to: path) }.buttonStyle(KikimimiButtonStyle.primary)
                    .disabled(!state.segmentsAvailable || exporting || env.termination.requested)
            } else {
                Button("書き出し先を設定") { openSettings() }.buttonStyle(KikimimiButtonStyle.secondary)
            }
        }
    }
    private var documentTabs: some View {
        HStack(spacing: 24) {
            ForEach(SessionDocumentTab.allCases, id: \.self) { tab in
                Button(tab.rawValue) { state.tab = tab }
                    .buttonStyle(state.tab == tab ? KikimimiButtonStyle.primary : .text)
                    .accessibilityAddTraits(state.tab == tab ? .isSelected : [])
            }
            Spacer()
            Button("録音の情報") { showingInfo = true }.buttonStyle(KikimimiButtonStyle.text)
        }
    }
    @ViewBuilder private var exportStatus: some View {
        if let exported = state.meta?.export {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(exported.path) に書き出しました（\(SessionDate.string(exported.at))）")
                    .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary).textSelection(.enabled)
                Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exported.path)]) }
                    .buttonStyle(KikimimiButtonStyle.text)
                if state.exportOutdated {
                    Text("書き出し後に文字起こしか要約が更新されています")
                        .kikimimiText(.small).foregroundStyle(KikimimiColor.warning)
                }
            }
        }
    }
    private func exportNote(to path: String) {
        guard !exporting else { return }
        exporting = true; actionError = nil
        Task {
            defer { exporting = false }
            do {
                try await env.store.exportNote(session.ref, to: URL(fileURLWithPath: path, isDirectory: true))
                await state.refresh(store: env.store)
            } catch { actionError = "書き出せませんでした: \(error.localizedDescription)" }
        }
    }
    private func copyMarkdown() {
        actionError = nil
        do {
            let markdown = try String(contentsOf: session.ref.folder.transcript, encoding: .utf8)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(markdown, forType: .string) else {
                actionError = "クリップボードに書き込めませんでした"; return
            }
            copied = true
        } catch { actionError = "Markdownを読み込めませんでした: \(error.localizedDescription)" }
    }
}
