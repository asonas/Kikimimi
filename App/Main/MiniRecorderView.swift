import AppKit
import SwiftUI
import RecorderCore

struct MiniRecorderView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .recording(let recording) = env.recorder.phase {
                HStack(spacing: 8) {
                    SettingsStatus(text: "録音中", ready: false, showsDot: true)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(RecordingElapsed.string(startedAt: recording.startedAt, now: context.date))
                            .kikimimiText(.heading).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button {
                        env.navigation.showSession(recording.ref)
                        env.recorderWindows.expand()
                    } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(KikimimiButtonStyle.text)
                    .help("録音画面を開く").accessibilityLabel("録音画面を開く")
                    Button("録音を停止") { Task { await env.recorder.stop() } }
                        .buttonStyle(KikimimiButtonStyle.danger)
                }
                ForEach([Track.me, .remote], id: \.self) { track in
                    let label = track == .me ? "自分" : "相手"
                    let failed = isFailed(recording.health[track])
                    LiveLevelMeter(channel: label, sample: env.recorder.meterLevels?[track], failed: failed, compact: true)
                    if failed {
                        Text("\(label)の音声が途切れました").kikimimiText(.small).foregroundStyle(KikimimiColor.warning)
                    }
                }
            } else {
                Text("録音を保存しています").kikimimiText(.label)
            }
        }
        .padding(16).frame(width: 380)
        .foregroundStyle(KikimimiColor.ink).background(KikimimiColor.surface)
        .background(RecorderWindowCapture { env.recorderWindows.captureMini($0) }.frame(width: 0, height: 0))
        .task(id: isIdle) {
            // A window restored at launch has no recording to show.
            if isIdle { dismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow { env.recorderWindows.miniClosed(window) }
        }
    }
    private var isIdle: Bool { if case .idle = env.recorder.phase { true } else { false } }
    private func isFailed(_ health: TrackHealth) -> Bool { if case .failed = health { true } else { false } }
}
