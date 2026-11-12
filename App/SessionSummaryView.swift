import SwiftUI
import RecorderCore
import RecorderSummary

struct SessionSummaryView: View {
    let env: AppEnvironment
    let ref: SessionRef
    let transcriptAvailable: Bool
    @State private var summary: String?
    @State private var error: String?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if summary == nil, !isRunning {
                Text("面接の要点をまとめる").kikimimiText(.heading)
            }
            if isRunning {
                HStack {
                    ProgressView("要約を作成しています").tint(KikimimiColor.ink)
                    Button("キャンセル") { env.summaryJobs.cancel(ref: ref) }.buttonStyle(KikimimiButtonStyle.secondary)
                }
            } else if summary == nil {
                Button("要約を作成", action: requestSummary).buttonStyle(KikimimiButtonStyle.primary).disabled(unavailableReason != nil)
                Text("作成するときに、文字起こしをOpenAIへ送信します。")
                    .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
            }
            if let reason = unavailableReason { Text(reason).kikimimiText(.small).foregroundStyle(KikimimiColor.secondary) }
            if let error { Text(error).foregroundStyle(KikimimiColor.danger).textSelection(.enabled) }
            if case .failed(let message) = job { Text(message).foregroundStyle(KikimimiColor.danger).textSelection(.enabled) }
            if let summary {
                SummaryMarkdownView(markdown: summary).frame(maxWidth: 888, alignment: .leading)
                MainDivider()
                HStack(spacing: 12) {
                    Text("要約はOpenAIのモデルが書いた文章です。気になるところは文字起こしで確かめてください。")
                        .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                    Spacer()
                    Button("作り直す", action: requestSummary).buttonStyle(KikimimiButtonStyle.secondary)
                        .disabled(isRunning || unavailableReason != nil)
                }
            }
        }
        .sheet(isPresented: $confirming) {
            MainSheet {
                Text("文字起こしを送信して要約します").kikimimiText(.heading)
                Text("この録音の文字起こしをOpenAIへ送信します。\n音声ファイルは送信しません。").kikimimiText(.body)
                Text("次回からは「要約を作成」を押すと送信します。")
                    .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                HStack {
                    Button("キャンセル") { confirming = false }.buttonStyle(KikimimiButtonStyle.secondary)
                    Spacer()
                    Button("送信して要約を作成") {
                        env.settings.settings.summaryConsent = true; confirming = false; start()
                    }
                    .buttonStyle(KikimimiButtonStyle.primary).disabled(unavailableReason != nil)
                }
            }
        }
        .task(id: ref) {
            env.summaryCredentials.refresh()
            await env.chatGPT.refresh()
            loadSummary()
        }
        .onChange(of: job) { _, job in
            if case .finished = job { loadSummary() }
            if case .running = job { error = nil }
        }
    }

    private var job: SummaryJob? { env.summaryJobs.jobs[ref] }
    private var isRunning: Bool { job == .running }
    private var unavailableReason: String? {
        if !transcriptAvailable { return "要約には文字起こしが必要です" }
        if !env.summaryProviderReady { return "要約には設定でChatGPTにサインインするか、APIキーを保存してください" }
        if env.settings.settings.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "設定で要約モデルを選んでください" }
        return nil
    }
    private func requestSummary() {
        if env.settings.settings.summaryConsent { start() } else { confirming = true }
    }

    private func start() {
        error = nil
        env.summaryJobs.start(ref: ref)
    }

    private func loadSummary() {
        guard FileManager.default.fileExists(atPath: ref.folder.summary.path) else { summary = nil; return }
        do { summary = try String(contentsOf: ref.folder.summary, encoding: .utf8) }
        catch { self.error = "要約を読み込めませんでした: \(error.localizedDescription)" }
    }
}

private struct SummaryMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                switch SummaryLine.classify(String(line)) {
                case .heading(let text):
                    Text(inline(text)).kikimimiText(.heading).padding(.top, 12)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let text, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("・")
                        Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .kikimimiText(.body).padding(.leading, CGFloat(depth) * 16)
                case .paragraph(let text):
                    Text(inline(text)).kikimimiText(.body).frame(maxWidth: .infinity, alignment: .leading)
                case .blank:
                    Color.clear.frame(height: 8).accessibilityHidden(true)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
