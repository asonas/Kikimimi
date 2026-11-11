import SwiftUI
import RecorderCore

struct SessionActivityView: View {
    let env: AppEnvironment
    let session: SessionListing
    let state: SessionDetailState
    let job: TranscriptionJobState?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if case .recording(let recording) = env.recorder.phase, recording.ref == session.ref {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("録音中").kikimimiText(.heading).foregroundStyle(KikimimiColor.danger)
                        Text(recording.startedAt, style: .timer).kikimimiText(.number)
                        Spacer()
                        Button("録音を停止") { Task { await env.recorder.stop() } }.buttonStyle(KikimimiButtonStyle.danger)
                    }
                    TrackMeter(label: "自分", peak: env.recorder.levels?.me, health: recording.health.me)
                    TrackMeter(label: "相手", peak: env.recorder.levels?.remote, health: recording.health.remote)
                }
                .padding(24).background(KikimimiColor.paper, in: RoundedRectangle(cornerRadius: 8))
            } else if env.localCapture(for: session.ref) == .stopping {
                ProgressView("録音を保存しています").tint(KikimimiColor.ink)
            } else if session.state == .capturing {
                Text("別のアプリで録音中です").kikimimiText(.body)
            }
            if let meta = state.meta {
                ForEach([Track.me, .remote], id: \.self) { track in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track == .me ? "自分の音声" : "相手の音声").kikimimiText(.heading)
                        Text(SessionTrackPresentation.text(track, meta: meta)).kikimimiText(.label).textSelection(.enabled)
                    }
                }
            }
            switch job {
            case .running(let fraction):
                ProgressView(SessionPage.statusText(state: session.state, job: job, localCapture: .none, hasSummary: session.hasSummary),
                             value: fraction.isFinite ? min(1, max(0, fraction)) : 0).tint(KikimimiColor.ink)
            case .queued, .waiting: Text(job?.label ?? "文字起こし待ち").kikimimiText(.label)
            case .failed(let message): Text("文字起こしに失敗しました: \(message)").foregroundStyle(KikimimiColor.danger).textSelection(.enabled)
            default: EmptyView()
            }
            if case .unusable(let message) = session.state {
                Text("録音を確認してください: \(message)").foregroundStyle(KikimimiColor.warning).textSelection(.enabled)
            }
            if session.state == .needsFinalize {
                Text("録音の保存処理を完了できませんでした。録音の情報から音声を確認してください。")
                    .kikimimiText(.body).foregroundStyle(KikimimiColor.warning)
            }
            if session.state == .readyToTranscribe || session.state == .transcribed {
                Button("文字起こしをやり直す") { env.transcription.enqueue(session.ref) }
                    .buttonStyle(KikimimiButtonStyle.secondary)
                    .disabled(job?.isBusy == true || env.termination.requested)
            }
        }
    }
}
