import AppKit
import SwiftUI
import RecorderCore

struct SessionInfoSheet: View {
    let env: AppEnvironment
    let session: SessionListing
    let state: SessionDetailState
    let job: TranscriptionJobState?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        MainSheet {
            Text("録音の情報").kikimimiText(.heading)
            VStack(spacing: 0) {
                row("会社名", session.company)
                row("タイトル", session.title ?? "—")
                row("日時", SessionDate.detail(session.startedAt, timeZone: state.meta.flatMap { TimeZone(identifier: $0.timeZone) }))
                row("録音時間", session.durationSeconds.map(SessionDate.duration) ?? "—")
                row("自分の音声", SessionTrackPresentation.text(.me, meta: state.meta))
                row("相手の音声", SessionTrackPresentation.text(.remote, meta: state.meta))
            }
            HStack(spacing: 12) {
                Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([session.ref.folder.url]) }
                Button("文字起こしをやり直す") { env.transcription.enqueue(session.ref); dismiss() }
                    // A new transcript arriving while the automatic run summarizes the old one would mix the two in one note.
                    .disabled((session.state != .readyToTranscribe && session.state != .transcribed) || job?.isBusy == true
                              || env.termination.requested || env.autoFollowUp.isRunning(session.ref))
            }
            .buttonStyle(KikimimiButtonStyle.secondary)
            Button("閉じる") { dismiss() }.buttonStyle(KikimimiButtonStyle.text)
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Text(label).kikimimiText(.small).foregroundStyle(KikimimiColor.secondary).frame(width: 130, alignment: .leading)
                Text(value).kikimimiText(.label).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .padding(.vertical, 20)
            MainDivider()
        }
    }
}

enum SessionTrackPresentation {
    static func text(_ track: Track, meta: SessionMeta?) -> String {
        guard let meta else { return "録音情報を読み込んでいます" }
        guard let value = meta.tracks[track] else { return "音声なし" }
        let status: String
        if let failure = value.failure { status = "入力の停止: \(failure.message)" }
        else if let audio = value.audio { status = audio.isEffectivelySilent ? "無音のため文字起こしを省略" : "保存済み" }
        else { status = meta.capture == .inProgress ? "録音中" : "音声は未保存" }
        return "\(value.source.displayName) / \(status)"
    }
}

extension TrackSource {
    var displayName: String {
        switch self {
        case .mic(_, let name, let channel, _): name + (channel.map { " · INPUT \($0)" } ?? " · 全チャンネル")
        case .app(_, let name): name
        case .allSystemAudio: "全システム音"
        }
    }
}
