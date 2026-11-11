import AppKit
import SwiftUI
import RecorderCore

struct SavedSessionView: View {
    let env: AppEnvironment
    let session: SessionListing
    let job: TranscriptionJobState?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("録音を保存しました").kikimimiText(.label).foregroundStyle(KikimimiColor.success)
                Text("自分と相手の音声は、このMacに保存されています。")
                    .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(KikimimiColor.successBg, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(panelTitle).kikimimiText(.heading).foregroundStyle(panelColor)
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
                if case .failed(let message) = job {
                    Text(message).kikimimiText(.small).foregroundStyle(KikimimiColor.danger).textSelection(.enabled)
                    Button("再試行") { env.transcription.enqueue(session.ref) }
                        .buttonStyle(KikimimiButtonStyle.secondary).disabled(env.termination.requested)
                } else if job == nil || job == .done {
                    Button("文字起こしを開始") { env.transcription.enqueue(session.ref) }
                        .buttonStyle(KikimimiButtonStyle.secondary).disabled(env.termination.requested)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(32)
            .background(KikimimiColor.paper, in: RoundedRectangle(cornerRadius: 8))
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
    private var fraction: Double {
        guard case .running(let value) = job, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
    private var panelTitle: String {
        switch job {
        case .running: "文字起こし中"
        case .waiting(.recordingInProgress): "録音が終わるのを待っています"
        case .waiting(.modelNotReady): "モデルをダウンロードしてください"
        case .failed: "文字起こしができませんでした"
        default: "文字起こしを待っています"
        }
    }
    private var panelDescription: String {
        switch job {
        case .waiting(.recordingInProgress): "音声は保存済みです。いまの録音が終わると、文字起こしを再開します。"
        case .waiting(.modelNotReady): "音声は録音できます。文字起こしには、最初にモデルの準備が必要です。"
        case .failed: "録音した音声は保存されています。もう一度お試しください。"
        case .queued: "音声は保存済みです。順番が来ると、文字起こしを開始します。"
        case nil, .done: "音声は保存済みです。文字起こしを開始できます。"
        default: "このMacで音声を文字にしています。\n別の録音を読んだり、ウィンドウを閉じたりしても処理は続きます。"
        }
    }
    private var panelColor: Color {
        switch job {
        case .failed: KikimimiColor.danger
        case .waiting: KikimimiColor.warning
        default: KikimimiColor.ink
        }
    }
}
