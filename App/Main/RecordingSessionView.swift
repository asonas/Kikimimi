import SwiftUI
import RecorderCore

struct RecordingSessionView: View {
    let env: AppEnvironment
    let recording: RecordingPhase.Recording
    let meta: SessionMeta?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 24) {
                SettingsStatus(text: "録音中", ready: false, showsDot: true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(RecordingElapsed.string(startedAt: recording.startedAt, now: context.date)).kikimimiText(.time)
                }
                Spacer()
                Button("小さく表示") { env.recorderWindows.showMini() }.buttonStyle(KikimimiButtonStyle.secondary)
                Button("録音を停止") { Task { await env.recorder.stop() } }.buttonStyle(KikimimiButtonStyle.danger)
            }
            VStack(alignment: .leading, spacing: 16) {
                track(.me)
                track(.remote)
            }
            if recording.health.me == .live, recording.health.remote == .live {
                SettingsStatus(text: "両方の音声を受信しています", showsDot: true)
            }
            if !hasFailure {
                MainDivider()
                Text("ウィンドウを閉じても録音は続きます。\nメニューバーからも録音を止められます。")
                    .kikimimiText(.body).foregroundStyle(KikimimiColor.secondary)
                HStack {
                    Text("音声はこのMacに保存されます。")
                    Spacer()
                    Text("文字起こしは録音終了後")
                }
                .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
            }
        }
    }
    @ViewBuilder private func track(_ track: Track) -> some View {
        let health = recording.health[track]
        let other = recording.health[track == .me ? .remote : .me]
        let label = track == .me ? "自分" : "相手"
        let name = meta?.tracks[track]?.source.displayName ?? (track == .me ? "マイク" : "音声アプリ")
        let failed = isFailed(health)
        LiveLevelMeter(channel: "\(label)  ·  \(name)", sample: env.recorder.meterLevels?[track], failed: failed)
        if failed {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(label)の音声が途切れました").kikimimiText(.label).foregroundStyle(KikimimiColor.warning)
                Text(track == .me
                     ? "マイクの接続を確認してください。今の録音では入力を再開できないため、停止してから録音をやり直してください。"
                     : "録音するアプリを確認してください。今の録音では入力を再開できないため、停止してから録音をやり直してください。")
                    .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(KikimimiColor.warningBg, in: RoundedRectangle(cornerRadius: 8))
        } else if isFailed(other), health == .live {
            SettingsStatus(text: "\(label)の音声は録音を続けています", showsDot: true)
        } else if health != .live {
            Text(health.label).kikimimiText(.small)
                .foregroundStyle(health.isProblem ? KikimimiColor.warning : KikimimiColor.secondary)
        }
    }
    private var hasFailure: Bool { isFailed(recording.health.me) || isFailed(recording.health.remote) }
    private func isFailed(_ health: TrackHealth) -> Bool { if case .failed = health { true } else { false } }
}
