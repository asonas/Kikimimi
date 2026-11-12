import AppKit
import SwiftUI
import RecorderCore

struct SavedSessionView: View {
    let env: AppEnvironment
    let session: SessionListing
    let job: TranscriptionJobState?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Notice(tone: .success, title: "録音を保存しました", message: "自分と相手の音声は、このMacに保存されています。")
            switch job {
            case .waiting(.modelNotReady):
                Notice(tone: .warning, title: "モデルをダウンロードしてください",
                       message: "音声は録音できます。文字起こしには、最初にモデルの準備が必要です。",
                       action: .init(label: "ダウンロード", isEnabled: {
                           switch env.transcription.model {
                           case .downloading, .optimizing: false
                           default: !env.recorder.phase.isCapturing && !env.termination.requested
                           }
                       }()) { Task { await env.transcription.installModel() } })
            case .waiting(.recordingInProgress):
                Notice(tone: .warning, title: "録音が終わるのを待っています",
                       message: "音声は保存済みです。いまの録音が終わると、文字起こしを再開します。")
            case .failed(let message):
                Notice(tone: .danger, title: "文字起こしができませんでした",
                       message: "録音した音声は保存されています。もう一度お試しください。",
                       action: .init(label: "やり直す", isEnabled: !env.termination.requested) { env.transcription.enqueue(session.ref) })
                Text(message).kikimimiText(.small).foregroundStyle(KikimimiColor.danger).textSelection(.enabled)
            default:
                progressPanel
            }
            HStack {
                Text("音声ファイルを確認する").kikimimiText(.label)
                Spacer()
                Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([session.ref.folder.url]) }
                    .buttonStyle(KikimimiButtonStyle.secondary)
            }
            Button("録音一覧に戻る") { env.navigation.showList() }
                .buttonStyle(KikimimiButtonStyle.secondary).padding(.top, 80)
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(panelTitle).kikimimiText(.heading)
                Spacer()
                if case .running = job { Text("\(Int(fraction * 100))%").kikimimiText(.heading).monospacedDigit() }
            }
            if case .running = job {
                GeometryReader { geometry in
                    Rectangle().fill(KikimimiColor.selected)
                    Rectangle().fill(KikimimiColor.ink).frame(width: geometry.size.width * fraction)
                }
                .frame(height: 6).accessibilityElement(children: .ignore)
                .accessibilityLabel("文字起こし、\(Int(fraction * 100))パーセント")
            }
            Text(panelDescription).kikimimiText(.body).foregroundStyle(KikimimiColor.secondary)
            if job == nil || job == .done {
                Button("文字起こしを開始") { env.transcription.enqueue(session.ref) }
                    .buttonStyle(KikimimiButtonStyle.secondary).disabled(env.termination.requested)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(32)
        .background(KikimimiColor.paper, in: RoundedRectangle(cornerRadius: 8))
    }
    private var fraction: Double {
        guard case .running(let value) = job, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
    private var panelTitle: String {
        if case .running = job { "文字起こし中" } else { "文字起こしを待っています" }
    }
    private var panelDescription: String {
        switch job {
        case .queued: "音声は保存済みです。順番が来ると、文字起こしを開始します。"
        case nil, .done: "音声は保存済みです。文字起こしを開始できます。"
        default: "このMacで音声を文字にしています。\n別の録音を読んだり、ウィンドウを閉じたりしても処理は続きます。"
        }
    }
}
