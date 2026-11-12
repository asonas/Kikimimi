import AppKit
import SwiftUI
import RecorderCore

struct SessionActivityView: View {
    let env: AppEnvironment
    let session: SessionListing
    let state: SessionDetailState
    let job: TranscriptionJobState?
    var body: some View {
        switch SessionPage.resolve(state: session.state, job: job, localCapture: env.localCapture(for: session.ref)) {
        case .recording:
            if case .recording(let recording) = env.recorder.phase {
                RecordingSessionView(env: env, recording: recording, meta: state.meta)
            }
        case .saving:
            VStack(alignment: .leading, spacing: 12) {
                Text("録音を保存しています").kikimimiText(.label)
                ProgressView().progressViewStyle(.linear).tint(KikimimiColor.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(KikimimiColor.paper, in: RoundedRectangle(cornerRadius: 8))
        case .transcribing:
            SavedSessionView(env: env, session: session, job: job)
        case .needsAttention:
            VStack(alignment: .leading, spacing: 24) {
                if session.state == .capturing {
                    Notice(tone: .warning, title: "別のアプリで録音中です")
                }
                if session.state == .needsFinalize {
                    Notice(tone: .warning, title: "録音の保存を完了できませんでした",
                           message: "録音の情報から音声を確認してください。")
                }
                if case .unusable(let message) = session.state {
                    VStack(alignment: .leading, spacing: 12) {
                        Notice(tone: .danger, title: "録音を確認してください")
                        Text(message).kikimimiText(.small).foregroundStyle(KikimimiColor.danger).textSelection(.enabled)
                    }
                }
                ForEach([Track.me, .remote], id: \.self) { track in
                    Text(SessionTrackPresentation.text(track, meta: state.meta)).kikimimiText(.label).textSelection(.enabled)
                }
                Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([session.ref.folder.url]) }
                    .buttonStyle(KikimimiButtonStyle.secondary)
            }
        case .document: EmptyView()
        }
    }
}
