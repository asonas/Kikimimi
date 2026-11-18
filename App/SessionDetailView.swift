import AppKit
import OSLog
import SwiftUI
import RecorderCore

struct SessionDetailView: View {
    let env: AppEnvironment
    let session: SessionListing
    @State private var state: SessionDetailState
    @Environment(\.openSettings) private var openSettings
    @State private var showingInfo = false
    @State private var copied = false
    @State private var exportStep: NoteExportStep?
    @State private var actionError: String?
    @State private var exportFailed = false

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
                autoFollowUpNotice
                if exportFailed || autoState == .exportFailed {
                    Notice(tone: .danger, title: "ノートを書き出せませんでした",
                           action: .init(label: "保存先を確認", perform: showExportSettings))
                }
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
                Button("文字起こしに戻る") { state.tab = .transcript; copied = false }
                    .buttonStyle(KikimimiButtonStyle.primary)
            }
        }
        .sheet(isPresented: Binding(get: { exportStep != nil }, set: { presented in
            if !presented, !isExporting { exportStep = nil }
        })) {
            if let exportStep {
                NoteExportSheet(step: exportStep,
                                target: [session.company, session.title].compactMap { $0 }.joined(separator: " / "),
                                hasSummary: session.hasSummary,
                                cancel: { if case .confirming = self.exportStep { self.exportStep = nil } }, confirm: exportNote,
                                close: { self.exportStep = nil })
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
            if env.settings.settings.exportFolder != nil {
                Button("ノートを書き出す", action: requestExport).buttonStyle(KikimimiButtonStyle.primary)
                    .disabled(!state.segmentsAvailable || isExporting || env.termination.requested || env.autoFollowUp.isRunning(session.ref))
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
            }
        }
        if state.exportOutdated {
            Notice(tone: .warning, title: "書き出したノートより新しい内容があります",
                   action: .init(label: "もう一度書き出す",
                                 isEnabled: env.settings.settings.exportFolder != nil && state.segmentsAvailable && !isExporting
                                     && !env.termination.requested && !env.autoFollowUp.isRunning(session.ref),
                                 perform: requestExport))
        }
    }
    private var autoState: AutoFollowUpState? { env.autoFollowUp.states[session.ref] }
    @ViewBuilder private var autoFollowUpNotice: some View {
        switch autoState {
        case .summaryFailed:
            Notice(tone: .danger, title: "要約できなかったため、ノートを書き出していません",
                   message: "もう一度試すと、要約してからノートを書き出します。",
                   action: .init(label: "もう一度試す", isEnabled: !env.termination.requested) { env.autoFollowUp.retry(session.ref) })
        case .skipped(let missing):
            Notice(tone: .warning, title: "自動の要約と書き出しをしませんでした",
                   message: "\(missing.map(\.shortLabel).joined(separator: "、"))が設定されていませんでした。設定を済ませてから、要約とノートの書き出しをしてください。",
                   action: .init(label: "設定を開く") { showSettings(missing.first?.settingsPane ?? .export) })
        case .running, .exportFailed, nil:
            EmptyView()
        }
    }
    private var isExporting: Bool { if case .exporting = exportStep { true } else { false } }
    private func requestExport() {
        guard exportStep == nil, let path = env.settings.settings.exportFolder else { return }
        exportStep = .confirming(URL(fileURLWithPath: path, isDirectory: true))
    }
    private func exportNote(to destination: URL) {
        guard case .confirming(let confirmed) = exportStep, confirmed == destination else { return }
        // The automatic run may have started after the sheet opened; it writes the same note.
        if env.autoFollowUp.isRunning(session.ref) { exportStep = nil; return }
        exportStep = .exporting(destination); actionError = nil; exportFailed = false
        Task {
            do {
                let exported = try await env.store.exportNote(session.ref, to: destination)
                await state.refresh(store: env.store)
                env.autoFollowUp.clear(session.ref)
                exportStep = .done(exported)
            } catch {
                exportStep = nil
                exportFailed = true
                Logger(subsystem: "as.ason.Kikimimi", category: "export").error("Note export failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
    private func showExportSettings() { showSettings(.export) }
    private func showSettings(_ pane: SettingsPane) {
        UserDefaults.standard.set(pane.rawValue, forKey: "settings.selectedPane")
        openSettings()
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
