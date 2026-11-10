import SwiftUI
import RecorderCore

enum SessionDocumentTab: String, CaseIterable {
    case summary = "要約"
    case transcript = "書き起こし"
}

struct SessionDocumentView: View {
    let env: AppEnvironment
    @Bindable var state: SessionDetailState

    var body: some View {
        VStack(spacing: 0) {
            Picker("表示", selection: $state.tab) {
                ForEach(SessionDocumentTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)
            Divider()
            // Keep both documents mounted so switching tabs doesn't cancel an in-flight summary.
            ZStack(alignment: .topLeading) {
                ScrollView {
                    SessionSummaryView(env: env, ref: state.ref, transcriptAvailable: state.markdownAvailable) {
                        state.tab = .summary
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .opacity(state.tab == .summary ? 1 : 0)
                .allowsHitTesting(state.tab == .summary)
                .accessibilityHidden(state.tab != .summary)
                ScrollView {
                    SessionTranscriptView(display: state.transcript)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .opacity(state.tab == .transcript ? 1 : 0)
                .allowsHitTesting(state.tab == .transcript)
                .accessibilityHidden(state.tab != .transcript)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SessionTranscriptView: View {
    let display: SessionTranscriptDisplay

    var body: some View {
        switch display {
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
}
