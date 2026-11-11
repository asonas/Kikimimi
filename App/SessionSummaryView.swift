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
        VStack(alignment: .leading, spacing: 12) {
            Text("要約").font(.title2.bold())
            if summary == nil, !isRunning {
                Text("書き起こしから面接の要点をまとめられます").foregroundStyle(.secondary)
            }
            if isRunning {
                HStack {
                    ProgressView("要約を作成しています")
                    Button("キャンセル") { env.summaryJobs.cancel(ref: ref) }
                }
            } else {
                Button(summary == nil ? "要約を作成" : "要約を作り直す") {
                    if env.settings.settings.summaryConsent { start() }
                    else { confirming = true }
                }
                .disabled(!transcriptAvailable || !env.summaryProviderReady ||
                          env.settings.settings.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !env.summaryProviderReady {
                    Text("要約には設定でChatGPTにサインインするか、APIキーを保存してください").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if case .failed(let message) = job { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if let summary {
                SummaryMarkdownView(markdown: summary)
            }
        }
        .confirmationDialog("書き起こしをOpenAIに送信しますか？", isPresented: $confirming, titleVisibility: .visible) {
            Button("送信して要約を作成") { env.settings.settings.summaryConsent = true; start() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("要約を作成するため、この面接の書き起こしテキストをOpenAIへ送信します。音声は送信しません。次回からは要約ボタンで送信します")
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
                    Text(inline(text)).font(.title3.bold()).padding(.top, 12)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let text, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 12 + CGFloat(depth) * 16)
                case .paragraph(let text):
                    Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
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
